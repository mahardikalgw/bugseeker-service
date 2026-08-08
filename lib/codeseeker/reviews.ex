defmodule Codeseeker.Reviews do
  @moduledoc """
  Persistence for PR review runs (idempotency) and the issues produced by
  the per-file LLM reviews, plus the review state machine.
  """

  import Ecto.Query

  alias Codeseeker.Repo
  alias Codeseeker.Reviews.{PrReview, ReviewIssue}
  alias Codeseeker.Reviews.Issue

  @doc """
  Creates a review run for a PR at `head_sha`. Returns `{:error, :duplicate}`
  when a run for the same `(github_repo_id, pr_number, head_sha)` already
  exists, making webhook redelivery idempotent.
  """
  @spec create_pr_review(map()) :: {:ok, PrReview.t()} | {:error, :duplicate}
  def create_pr_review(attrs) do
    case Repo.insert(PrReview.changeset(%PrReview{}, attrs)) do
      {:ok, pr_review} ->
        {:ok, pr_review}

      {:error, %Ecto.Changeset{errors: [{:pr_reviews_unique_head, _} | _]}} ->
        {:error, :duplicate}

      {:error, _} ->
        {:error, :duplicate}
    end
  end

  @doc "Returns the existing run for the given PR + head_sha, or nil."
  @spec find_pr_review(integer(), integer(), String.t()) :: PrReview.t() | nil
  def find_pr_review(github_repo_id, pr_number, head_sha) do
    Repo.one(
      from(r in PrReview,
        where:
          r.github_repo_id == ^github_repo_id and r.pr_number == ^pr_number and
            r.head_sha == ^head_sha
      )
    )
  end

  @doc "Sets the run status to `processing`."
  @spec mark_processing(PrReview.t()) :: {:ok, PrReview.t()} | {:error, term()}
  def mark_processing(pr_review), do: set_status(pr_review, "processing")

  @doc "Stores the truncated repo guidelines on the run, if any were fetched."
  @spec store_guidelines(PrReview.t(), String.t() | nil) :: {:ok, PrReview.t()} | {:error, term()}
  def store_guidelines(pr_review, guidelines) do
    Repo.update(Ecto.Changeset.change(pr_review, guidelines: guidelines))
  end

  @doc """
  Stores the kept files (path + patch) that the agents will review, so each
  agent job reads the full diff from the run instead of duplicating it.
  """
  @spec store_files(PrReview.t(), [map()]) :: {:ok, PrReview.t()} | {:error, term()}
  def store_files(pr_review, files) do
    normalized =
      Enum.map(files, fn f ->
        %{
          "path" => Map.get(f, :path) || f["path"],
          "patch" => Map.get(f, :patch) || f["patch"],
          "additions" => Map.get(f, :additions) || f["additions"] || 0,
          "deletions" => Map.get(f, :deletions) || f["deletions"] || 0,
          "status" => Map.get(f, :status) || f["status"] || "modified",
          "sha" => Map.get(f, :sha) || f["sha"]
        }
      end)

    Repo.update(Ecto.Changeset.change(pr_review, files: normalized))
  end

  @doc "Stores the inline-severity threshold resolved for this run, if overridden."
  @spec store_min_inline_severity(PrReview.t(), String.t() | nil) ::
          {:ok, PrReview.t()} | {:error, term()}
  def store_min_inline_severity(pr_review, nil), do: {:ok, pr_review}

  def store_min_inline_severity(pr_review, severity) do
    Repo.update(Ecto.Changeset.change(pr_review, min_inline_severity: severity))
  end

  @doc "Records the number of files to review for a run."
  @spec set_total_files(PrReview.t(), non_neg_integer()) :: {:ok, PrReview.t()} | {:error, term()}
  def set_total_files(pr_review, total) do
    Repo.update(Ecto.Changeset.change(pr_review, total_files: total))
  end

  @doc """
  Atomically marks one file of a run as reviewed (under a row lock).

  Returns `:complete` when the last file finished (the caller should then
  run the aggregate job) or `:pending` otherwise. Called once per file job
  in its terminal (success or permanently-failed) state, so the aggregate
  always fires.
  """
  @spec complete_file(PrReview.t()) :: {:ok, :complete | :pending} | {:error, term()}
  def complete_file(%PrReview{id: pr_review_id}) do
    Repo.transaction(fn ->
      pr =
        Repo.one!(
          from(p in PrReview,
            where: p.id == ^pr_review_id,
            lock: "FOR UPDATE"
          )
        )

      {1, _} =
        Repo.update_all(
          from(p in PrReview, where: p.id == ^pr_review_id),
          inc: [files_reviewed: 1]
        )

      if pr.files_reviewed + 1 >= pr.total_files, do: :complete, else: :pending
    end)
  end

  @doc "Marks the run completed or failed."
  @spec finalize(PrReview.t(), String.t()) :: {:ok, PrReview.t()} | {:error, term()}
  def finalize(pr_review, status) when status in ["completed", "failed"],
    do: set_status(pr_review, status)

  defp set_status(pr_review, status) do
    Repo.update(PrReview.status_changeset(pr_review, status))
  end

  @doc """
  Persists a list of `%Review.Issue{}` for a review run.
  """
  @spec insert_issues(PrReview.t(), [Issue.t()]) :: {:ok, integer()} | {:error, term()}
  def insert_issues(%PrReview{id: pr_review_id}, issues) do
    now = DateTime.utc_now()

    entries =
      Enum.map(issues, fn issue ->
        %{
          pr_review_id: pr_review_id,
          file_path: issue.file_path,
          line: issue.line,
          severity: issue.severity,
          category: issue.category,
          skill_used: issue.agent || "generic",
          message: issue.message,
          recommendation: issue.recommendation,
          posted: false,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(ReviewIssue, entries)
    {:ok, count}
  end

  @doc """
  Loads all persisted issues for a run as `%Review.Issue{}` structs.
  """
  @spec issues_for(PrReview.t()) :: [Issue.t()]
  def issues_for(%PrReview{id: pr_review_id}) do
    query =
      from(i in ReviewIssue,
        where: i.pr_review_id == ^pr_review_id,
        order_by: [asc: i.file_path, asc: i.line]
      )

    Repo.all(query) |> Enum.map(&to_issue/1)
  end

  @doc "Marks the given issue ids as posted to GitHub."
  @spec mark_posted([integer()]) :: {integer(), nil}
  def mark_posted(ids) when ids == [], do: {0, nil}

  def mark_posted(ids) do
    Repo.update_all(from(i in ReviewIssue, where: i.id in ^ids), set: [posted: true])
  end

  @doc "Marks every issue of a run as posted (used by the aggregate job)."
  @spec mark_all_posted(PrReview.t()) :: {integer(), nil}
  def mark_all_posted(%PrReview{id: pr_review_id}) do
    Repo.update_all(from(i in ReviewIssue, where: i.pr_review_id == ^pr_review_id),
      set: [posted: true]
    )
  end

  @doc "Distinct agents used across a run (for the summary header)."
  @spec agents_for(PrReview.t()) :: [String.t()]
  def agents_for(%PrReview{id: pr_review_id}) do
    query =
      from(i in ReviewIssue,
        where: i.pr_review_id == ^pr_review_id,
        select: i.skill_used,
        distinct: true
      )

    Repo.all(query)
  end

  defp to_issue(%ReviewIssue{} = ri) do
    %Issue{
      file_path: ri.file_path,
      line: ri.line,
      severity: ri.severity,
      category: ri.category,
      message: ri.message,
      recommendation: ri.recommendation,
      agent: ri.skill_used
    }
  end
end
