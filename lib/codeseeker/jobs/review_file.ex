defmodule Codeseeker.Jobs.ReviewFileJob do
  @moduledoc """
  Reviews one file of a PR: resolve its skill, build the prompt, call the
  LLM, and persist any issues. The last file to finish enqueues
  `AggregateReviewJob`.

  Queue: `review`. Oban's `limit: 30` on this queue is the **global cap on
  concurrent DeepSeek calls** — this is what lets hundreds of PRs be
  processed without rate-limit storms. Transient LLM errors return
  `{:error, ...}` so Oban retries with backoff.
  """

  use Oban.Worker, queue: :review, max_attempts: 5

  require Logger

  alias Codeseeker.{Clients, Repo, Reviews}
  alias Codeseeker.Jobs.AggregateReviewJob
  alias Codeseeker.Llm.Parser
  alias Codeseeker.Llm.Prompt
  alias Codeseeker.Reviews.PrReview
  alias Codeseeker.Skills.Registry

  @impl true
  def perform(%Oban.Job{args: %{"pr_review_id" => pr_review_id, "file" => file}} = job) do
    case Repo.get(PrReview, pr_review_id) do
      nil ->
        :discard

      pr_review ->
        case review_file(pr_review, stringify_keys(file)) do
          {:ok, result} ->
            maybe_enqueue_aggregate(pr_review)
            {:ok, result}

          {:error, reason} ->
            # Permanent LLM failure: count the file as done so the aggregate
            # job still fires; otherwise Oban keeps retrying up to max_attempts.
            if job.attempt >= job.max_attempts do
              maybe_enqueue_aggregate(pr_review)
              {:ok, %{issues: 0, skipped: true}}
            else
              {:error, reason}
            end
        end
    end
  end

  defp review_file(pr_review, %{path: path} = file) do
    skill = Registry.resolve(path)
    prompt = Prompt.build(skill, file, pr_review.guidelines)
    started = System.monotonic_time(:millisecond)

    case Clients.llm().chat(prompt) do
      {:ok, %{content: content}} ->
        Codeseeker.Stats.record_deepseek(:ok)

        case Parser.parse(content, path, skill) do
          {:ok, issues} ->
            {:ok, _count} = Reviews.insert_issues(pr_review, issues)

            Logger.info("file_ok",
              pr_review_id: pr_review.id,
              path: path,
              skill: skill.name,
              issues: length(issues),
              duration_ms: duration_ms(started)
            )

            {:ok, %{issues: length(issues)}}

          {:error, :unparseable} ->
            Logger.warning("file_unparseable", path: path)
            {:ok, %{issues: 0, skipped: true}}
        end

      {:error, reason} ->
        # Transient DeepSeek error -> Oban retries with backoff.
        Logger.warning("file_llm_error", path: path, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp maybe_enqueue_aggregate(pr_review) do
    case Reviews.complete_file(pr_review) do
      {:ok, :complete} ->
        Logger.info("all files reviewed — enqueueing aggregate", pr_review_id: pr_review.id)
        Oban.insert(AggregateReviewJob.new(%{"pr_review_id" => pr_review.id}))
        :ok

      {:ok, :pending} ->
        :ok

      {:error, reason} ->
        Logger.error("complete_file failed", pr_review_id: pr_review.id, reason: inspect(reason))
        :error
    end
  end

  # The file args arrive string-keyed from Oban args.
  defp stringify_keys(file) do
    %{
      path: file["path"],
      patch: file["patch"],
      additions: file["additions"] || 0,
      deletions: file["deletions"] || 0,
      status: file["status"] || "modified",
      sha: file["sha"]
    }
  end

  defp duration_ms(started), do: System.monotonic_time(:millisecond) - started
end
