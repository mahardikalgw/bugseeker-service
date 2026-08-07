defmodule Codeseeker.Coordinator do
  @moduledoc """
  Orchestrates the full review of one PR: dedup guard → fetch diff →
  filter → guidelines → concurrent per-file LLM review → aggregate →
  post review.

  One GenServer per PR, started via `Codeseeker.CoordinatorSup`. All heavy
  work happens in `handle_continue` so the webhook endpoint can ack fast.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Codeseeker.{
    Clients,
    Dedup,
    Exclusions,
    Llm.Parser,
    Llm.Prompt,
    PerRepo,
    Review,
    Skills.Registry,
    Stats
  }

  @type pr :: %{
          repo: %{owner: String.t(), name: String.t(), installation_id: pos_integer()},
          pr_number: pos_integer(),
          head_sha: String.t(),
          base_sha: String.t()
        }

  def start_link(pr) do
    GenServer.start_link(__MODULE__, pr)
  end

  @impl true
  def init(pr) do
    {:ok, %{pr: pr}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, %{pr: pr} = state) do
    dedup_key = key(pr)

    outcome =
      case Dedup.begin_processing(dedup_key) do
        :duplicate ->
          {:skipped, :duplicate}

        :ok ->
          result = run_review(pr)
          Dedup.mark_done(dedup_key)
          result
      end

    log_outcome(outcome, pr)
    record_stats(outcome)
    {:stop, :normal, state}
  end

  ## Review pipeline

  defp run_review(pr) do
    cond do
      not PerRepo.enabled?(pr.repo) ->
        {:skipped, :repo_disabled}

      true ->
        case github_call(fn -> Clients.github().list_pr_files(pr.repo, pr.pr_number) end, pr) do
          {:ok, files} -> review_files_phase(pr, files)
          {:error, reason} -> {:failed, {:list_files, reason}}
        end
    end
  end

  defp review_files_phase(pr, files) do
    {kept, skipped} = Exclusions.filter(files)

    if kept == [] do
      {:skipped, :nothing_to_review}
    else
      guidelines = fetch_guidelines(pr)
      started = System.monotonic_time(:millisecond)

      results = review_files(kept, pr, guidelines)
      {issues, file_warnings} = collect_results(results)
      warnings = skipped_warnings(skipped) ++ file_warnings

      pr_skills =
        kept
        |> Enum.map(fn file -> Registry.resolve(file.path).name end)
        |> Enum.uniq()

      pr = Map.put(pr, :skills, pr_skills)

      aggregated = Review.aggregate(issues, patches_by_path(kept), skipped, warnings, pr)
      post_outcome = post_review(pr, aggregated)

      {:ok, %{issues: issues, skills: pr_skills, started: started, post: post_outcome}}
    end
  end

  defp fetch_guidelines(pr) do
    path = Application.get_env(:codeseeker, :guidelines_path, "docs/engineering-guidelines.md")

    case github_call(fn -> Clients.github().get_raw_contents(pr.repo, path, pr.base_sha) end, pr) do
      {:ok, content} ->
        String.slice(content, 0, 8_192)

      {:error, :not_found} ->
        nil

      {:error, reason} ->
        Logger.warning("guidelines fetch failed",
          repo: pr.repo.name,
          pr: pr.pr_number,
          reason: inspect(reason)
        )

        nil
    end
  end

  defp review_files(kept, pr, guidelines) do
    concurrency = Application.get_env(:codeseeker, :review_concurrency, 10)

    kept
    |> Task.async_stream(
      fn file -> review_file(file, pr, guidelines) end,
      max_concurrency: concurrency,
      timeout: 150_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, "timeout or exit: #{inspect(reason)}"}
    end)
  end

  defp review_file(file, pr, guidelines) do
    skill = Registry.resolve(file.path)
    prompt = Prompt.build(skill, file, guidelines)
    started = System.monotonic_time(:millisecond)

    case llm_retry(fn -> Clients.llm().chat(prompt) end, pr, file.path) do
      {:ok, %{content: content}} ->
        Stats.record_deepseek(:ok)

        case Parser.parse(content, file.path, skill) do
          {:ok, issues} ->
            {:ok, issues}

          {:error, :unparseable} ->
            repair_parse(prompt, content, file, skill, started)
        end

      {:error, reason} ->
        Stats.record_deepseek(:error)

        Logger.warning("file_failed",
          path: file.path,
          reason: inspect(reason),
          duration_ms: duration_ms(started)
        )

        {:error, reason}
    end
  end

  defp repair_parse(original_prompt, bad_content, file, skill, started) do
    repair =
      original_prompt <>
        "\n\n## REPAIR: Your previous output was not valid JSON: <<<" <>
        bad_content <> ">>>\nRepeat with ONLY valid JSON following the same schema."

    case Clients.llm().chat(repair) do
      {:ok, %{content: repaired}} ->
        case Parser.parse(repaired, file.path, skill) do
          {:ok, issues} -> {:ok, issues}
          {:error, :unparseable} -> {:error, "unparseable after repair"}
        end

      {:error, reason} ->
        Logger.warning("file_failed",
          path: file.path,
          reason: "repair failed: #{inspect(reason)}",
          duration_ms: duration_ms(started)
        )

        {:error, "repair failed: #{inspect(reason)}"}
    end
  end

  defp collect_results(results) do
    Enum.reduce(results, {[], []}, fn
      {:ok, issues}, {all, warnings} ->
        {all ++ issues, warnings}

      {:error, reason}, {all, warnings} ->
        {all, ["file failed to review: #{inspect(reason)}" | warnings]}
    end)
  end

  defp skipped_warnings(skipped) do
    Enum.map(skipped, fn %{path: path, reason: reason} -> "Skipped: #{path} (#{reason})" end)
  end

  defp patches_by_path(kept), do: Map.new(kept, &{&1.path, &1.patch})

  defp post_review(pr, aggregated) do
    body =
      if aggregated.summary_body == "" do
        default_body(pr)
      else
        aggregated.summary_body
      end

    case github_call(
           fn ->
             Clients.github().post_review(
               pr.repo,
               pr.pr_number,
               pr.head_sha,
               body,
               aggregated.inline
             )
           end,
           pr
         ) do
      {:ok, _response} ->
        :ok

      {:error, %{reason: :invalid_line}} ->
        Logger.info("inline demoted — invalid lines", repo: pr.repo.name, pr: pr.pr_number)

        case github_call(
               fn ->
                 Clients.github().post_review(pr.repo, pr.pr_number, pr.head_sha, body, [])
               end,
               pr
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:failed, inspect(reason)}
        end

      {:error, reason} ->
        {:failed, inspect(reason)}
    end
  end

  defp default_body(pr) do
    "## 🤖 Codeseeker Review — PR ##{pr.pr_number}\nAutomatic review on `#{String.slice(pr.head_sha, 0..7)}` — no issues found."
  end

  ## Retry helpers

  defp github_call(fun, pr) do
    backoffs = Application.get_env(:codeseeker, :github_retry_backoff_ms, [2_000, 6_000, 18_000])

    retry(fun, backoffs, 3, "github", pr, fn
      {:ok, _} -> false
      {:error, %{retryable?: true}} -> true
      _ -> false
    end)
  end

  defp llm_retry(fun, pr, path) do
    llm = Application.get_env(:codeseeker, :llm, %{})
    max_retries = llm[:max_retries] || 3
    backoffs = llm[:retry_backoff_ms] || [3_000, 9_000, 27_000]

    retry(
      fun,
      backoffs,
      max_retries,
      "deepseek",
      %{repo: pr.repo.name, pr: pr.pr_number, file: path},
      fn
        {:ok, _} -> false
        {:error, %{type: type}} when type in [:timeout, :rate_limited, :api_error] -> true
        _ -> false
      end
    )
  end

  defp retry(fun, backoffs, attempts_left, label, ctx, retryable?) do
    result = fun.()

    if retryable?.(result) and attempts_left > 1 do
      [backoff | rest] = backoffs
      rest = if rest == [], do: [backoff], else: rest
      Logger.warning("#{label} retryable failure", ctx: ctx, backoff_ms: backoff)
      Process.sleep(backoff)
      retry(fun, rest, attempts_left - 1, label, ctx, retryable?)
    else
      result
    end
  end

  ## Logging & stats

  defp log_outcome({:ok, %{issues: issues, skills: skills, post: post}}, pr) do
    Logger.info("review_finished",
      repo: "#{pr.repo.owner}/#{pr.repo.name}",
      pr: pr.pr_number,
      head_sha: pr.head_sha,
      issues: length(issues),
      skills: skills,
      post: post
    )
  end

  defp log_outcome({:skipped, reason}, pr) do
    Logger.info("review_skipped",
      repo: "#{pr.repo.owner}/#{pr.repo.name}",
      pr: pr.pr_number,
      reason: reason
    )
  end

  defp log_outcome({:failed, {phase, reason}}, pr) do
    Logger.error("review_failed",
      repo: "#{pr.repo.owner}/#{pr.repo.name}",
      pr: pr.pr_number,
      phase: phase,
      reason: inspect(reason)
    )
  end

  defp record_stats({:ok, %{issues: issues, started: started, post: post}}) do
    outcome = if post == :ok, do: :ok, else: :failed
    Stats.record(outcome, issues, duration_ms(started))
  end

  defp record_stats({:skipped, _reason}), do: Stats.record(:skipped, [], nil)
  defp record_stats({:failed, _}), do: Stats.record(:failed, [], nil)

  defp key(pr), do: {pr.repo.owner, pr.repo.name, pr.pr_number, pr.head_sha}

  defp duration_ms(started), do: System.monotonic_time(:millisecond) - started
end
