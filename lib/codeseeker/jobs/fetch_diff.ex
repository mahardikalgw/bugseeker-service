defmodule Codeseeker.Jobs.FetchDiffJob do
  @moduledoc """
  Intake for a PR: creates an idempotent review run, fetches the diff,
  filters files, stores the repo guidelines + kept files, and enqueues one
  `AgentJob` per review agent (Bug, Security, Performance, ...).

  The last agent to finish enqueues `AggregateReviewJob` (completion is
  tracked with a row-locked counter).

  Queue: `webhook` (low concurrency — GitHub payload intake).
  """

  use Oban.Worker, queue: :webhook, max_attempts: 5

  require Logger

  alias Codeseeker.{Clients, Exclusions, PerRepo, Reviews}

  @impl true
  def perform(%Oban.Job{args: args}) do
    repo = args["repo"]
    pr_number = args["pr_number"]

    if !PerRepo.enabled?(repo) do
      :discard
    else
      case Reviews.create_pr_review(review_attrs(args)) do
        {:error, :duplicate} ->
          Logger.info("fetch_diff duplicate — redelivery or concurrent", pr: pr_number)
          :discard

        {:ok, pr_review} ->
          process(pr_review, repo, pr_number, args["base_sha"])
      end
    end
  end

  defp process(pr_review, repo, pr_number, base_sha) do
    case Clients.github().list_pr_files(repo, pr_number) do
      {:ok, files} ->
        {kept, skipped} = Exclusions.filter(files)

        if kept == [] do
          Reviews.finalize(pr_review, "completed")
          Logger.info("fetch_diff nothing to review", pr: pr_number, skipped: length(skipped))
          {:ok, %{agents: 0}}
        else
          guidelines = fetch_guidelines(repo, base_sha)
          Reviews.store_guidelines(pr_review, guidelines)
          Reviews.store_files(pr_review, kept)
          Reviews.mark_processing(pr_review)

          agents = PerRepo.active_agent_names(repo)
          Reviews.set_total_files(pr_review, length(agents))
          enqueue_agent_jobs(pr_review, agents)

          Logger.info("fetch_diff enqueued agents",
            pr: pr_number,
            pr_review_id: pr_review.id,
            files: length(kept),
            agents: length(agents),
            skipped: length(skipped)
          )

          {:ok, %{agents: length(agents)}}
        end

      {:error, reason} ->
        # Raise so Oban retries with backoff.
        raise "list_pr_files failed: #{inspect(reason)}"
    end
  end

  defp fetch_guidelines(repo, base_sha) do
    path = Application.get_env(:codeseeker, :guidelines_path, "docs/engineering-guidelines.md")

    case Clients.github().get_raw_contents(repo, path, base_sha) do
      {:ok, content} ->
        String.slice(content, 0, 8_192)

      {:error, :not_found} ->
        nil

      {:error, reason} ->
        Logger.warning("guidelines fetch failed", reason: inspect(reason))
        nil
    end
  end

  defp enqueue_agent_jobs(pr_review, agents) do
    jobs =
      Enum.map(agents, fn agent ->
        Codeseeker.Jobs.AgentJob.new(%{"pr_review_id" => pr_review.id, "agent" => agent})
      end)

    Oban.insert_all(jobs)
  end

  defp review_attrs(args) do
    repo = args["repo"]

    %{
      github_repo_id: repo["github_repo_id"],
      owner: repo["owner"],
      name: repo["name"],
      installation_id: repo["installation_id"],
      pr_number: args["pr_number"],
      head_sha: args["head_sha"],
      base_sha: args["base_sha"]
    }
  end
end
