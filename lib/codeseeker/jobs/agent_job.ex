defmodule Codeseeker.Jobs.AgentJob do
  @moduledoc """
  Runs one review agent (Bug, Security, Performance, ...) against the whole
  PR diff. Builds an agent-specific prompt, calls the LLM, and persists the
  issues. The last agent to finish enqueues `AggregateReviewJob`.

  Queue: `review`. Oban's `limit: 30` on this queue is the **global cap on
  concurrent DeepSeek calls** across all agents and PRs. Transient LLM errors
  return `{:error, ...}` so Oban retries with backoff.
  """

  use Oban.Worker, queue: :review, max_attempts: 5

  require Logger

  alias Codeseeker.{Agents, Clients, Repo, Reviews}
  alias Codeseeker.Jobs.AggregateReviewJob
  alias Codeseeker.Llm.Parser
  alias Codeseeker.Llm.Prompt
  alias Codeseeker.Reviews.PrReview

  @impl true
  def perform(%Oban.Job{args: %{"pr_review_id" => pr_review_id, "agent" => agent_name}} = job) do
    with %PrReview{} = pr_review <- Repo.get(PrReview, pr_review_id),
         %{name: _} = agent <- Agents.Cache.get(agent_name) do
      result = run_agent(pr_review, agent)

      case result do
        {:ok, meta} ->
          maybe_enqueue_aggregate(pr_review)
          {:ok, meta}

        {:error, reason} ->
          if job.attempt >= job.max_attempts do
            maybe_enqueue_aggregate(pr_review)
            {:ok, %{issues: 0, skipped: true}}
          else
            {:error, reason}
          end
      end
    else
      _ -> :discard
    end
  end

  defp run_agent(pr_review, agent) do
    files = (pr_review.files || []) |> Enum.map(&stringify_keys/1)
    prompt = Prompt.build_agent(agent, files, pr_review.guidelines)
    started = System.monotonic_time(:millisecond)

    case Clients.llm().chat(prompt) do
      {:ok, %{content: content}} ->
        Codeseeker.Stats.record_deepseek(:ok)

        case Parser.parse(content, nil, agent) do
          {:ok, issues} ->
            {:ok, _count} = Reviews.insert_issues(pr_review, issues)

            Logger.info("agent_ok",
              pr_review_id: pr_review.id,
              agent: agent.name,
              issues: length(issues),
              duration_ms: duration_ms(started)
            )

            {:ok, %{issues: length(issues)}}

          {:error, :unparseable} ->
            Logger.warning("agent_unparseable", agent: agent.name)
            {:ok, %{issues: 0, skipped: true}}
        end

      {:error, reason} ->
        Logger.warning("agent_llm_error", agent: agent.name, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp maybe_enqueue_aggregate(pr_review) do
    case Reviews.complete_file(pr_review) do
      {:ok, :complete} ->
        Logger.info("all agents finished — enqueueing aggregate", pr_review_id: pr_review.id)
        Oban.insert(AggregateReviewJob.new(%{"pr_review_id" => pr_review.id}))
        :ok

      {:ok, :pending} ->
        :ok

      {:error, reason} ->
        Logger.error("complete_file failed", pr_review_id: pr_review.id, reason: inspect(reason))
        :error
    end
  end

  defp stringify_keys(%{"path" => path} = file) do
    %{
      path: path,
      patch: file["patch"],
      additions: file["additions"] || 0,
      deletions: file["deletions"] || 0,
      status: file["status"] || "modified",
      sha: file["sha"]
    }
  end

  defp duration_ms(started), do: System.monotonic_time(:millisecond) - started
end
