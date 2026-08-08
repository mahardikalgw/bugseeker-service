defmodule Codeseeker.Jobs.AggregateReviewJob do
  @moduledoc """
  Runs after all `ReviewFileJob`s of a PR finish (Oban batch callback).
  Loads the persisted issues, splits them into inline comments vs summary,
  posts the GitHub review (with a 422 invalid-line fallback that demotes
  inline comments to the summary), and finalizes the run.

  Queue: `review`.
  """

  use Oban.Worker, queue: :review, max_attempts: 3

  require Logger

  alias Codeseeker.{Clients, Repo, Reviews}
  alias Codeseeker.Reviews.Aggregator, as: Review
  alias Codeseeker.Reviews.PrReview

  @impl true
  def perform(%Oban.Job{args: %{"pr_review_id" => pr_review_id}} = job) do
    case Repo.get(PrReview, pr_review_id) do
      nil ->
        :discard

      pr_review ->
        result = build_and_post(pr_review)

        case result do
          :ok ->
            Reviews.mark_all_posted(pr_review)
            Reviews.finalize(pr_review, "completed")

          {:error, reason} ->
            if job.attempt >= job.max_attempts do
              Reviews.finalize(pr_review, "failed")
            end

            {:error, reason}
        end
    end
  end

  defp build_and_post(pr_review) do
    issues = Reviews.issues_for(pr_review)
    skills = Reviews.skills_for(pr_review)

    pr = %{
      repo: repo_map(pr_review),
      pr_number: pr_review.pr_number,
      head_sha: pr_review.head_sha,
      skills: skills
    }

    # Patches are not persisted in the Oban pipeline; line validity is
    # enforced by GitHub (422 fallback below).
    aggregated = Review.aggregate(issues, %{}, [], [], pr)
    post_review(pr_review, aggregated)
  end

  defp post_review(pr_review, aggregated) do
    repo = repo_map(pr_review)

    body =
      if aggregated.summary_body == "" do
        default_body(pr_review)
      else
        aggregated.summary_body
      end

    case Clients.github().post_review(
           repo,
           pr_review.pr_number,
           pr_review.head_sha,
           body,
           aggregated.inline
         ) do
      {:ok, _} ->
        :ok

      {:error, %{reason: :invalid_line}} ->
        Logger.info("aggregate inline demoted — invalid lines", pr_review_id: pr_review.id)

        demoted_body =
          body <>
            "\n### Notes\n" <>
            Enum.map_join(aggregated.demoted, "\n", fn issue ->
              "- **[inline failed — invalid line]** #{issue.file_path}##{issue.line}: #{issue.message}"
            end)

        case Clients.github().post_review(
               repo,
               pr_review.pr_number,
               pr_review.head_sha,
               demoted_body,
               []
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_body(pr_review) do
    "## 🤖 Codeseeker Review — PR ##{pr_review.pr_number}\nAutomatic review on `#{String.slice(pr_review.head_sha, 0..7)}` — no issues found."
  end

  defp repo_map(pr_review) do
    %{
      owner: pr_review.owner,
      name: pr_review.name,
      installation_id: pr_review.installation_id
    }
  end
end
