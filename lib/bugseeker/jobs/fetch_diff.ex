defmodule Bugseeker.Jobs.FetchDiffJob do
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

  alias Bugseeker.{Clients, Exclusions, PerRepo, RepoConfig, Reviews}

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
          process(pr_review, repo, pr_number, args["base_sha"], args["head_sha"])
      end
    end
  end

  defp process(pr_review, repo, pr_number, base_sha, head_sha) do
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

          repo_config = RepoConfig.fetch(repo, head_sha)
          agents = active_agents(repo, repo_config)

          Reviews.store_min_inline_severity(
            pr_review,
            repo_config && repo_config[:min_inline_severity]
          )

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

  # The repo's own `.bugseeker.yml` wins over PerRepo; without one (or
  # without an `agents` key in it) PerRepo decides.
  defp active_agents(repo, repo_config) do
    case repo_config && repo_config[:agents] do
      nil -> PerRepo.active_agent_names(repo)
      agents -> agents
    end
  end

  defp fetch_guidelines(repo, base_sha) do
    path = Application.get_env(:bugseeker, :guidelines_path, "docs/engineering-guidelines.md")

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
        Bugseeker.Jobs.AgentJob.new(%{"pr_review_id" => pr_review.id, "agent" => agent})
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
