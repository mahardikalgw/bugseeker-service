defmodule Bugseeker.Commands do
  @moduledoc """
  Handles `/bugseeker` commands posted as PR issue comments:

      /bugseeker enable-agent <name>
      /bugseeker disable-agent <name>
      /bugseeker status

  Replies are posted back to the PR as a comment. Runs asynchronously so
  the webhook endpoint can ack immediately.
  """

  require Logger

  alias Bugseeker.{Agents.Cache, Clients, PerRepo}

  @command_regex ~r{^/bugseeker\s+(enable-agent|disable-agent|status)(\s+(\w+))?\s*$}i

  @doc """
  Parses a command body and dispatches it. `ctx` is a map with `:repo`,
  `:pr_number`, `:comment` (the full comment body) and `:user`.
  """
  @spec run(map()) :: :ok
  def run(%{repo: repo, pr_number: pr_number, comment: comment} = ctx) do
    case Regex.run(@command_regex, comment || "") do
      [_, "enable-agent", _, agent_name] -> enable_agent(ctx, repo, pr_number, agent_name)
      [_, "disable-agent", _, agent_name] -> disable_agent(ctx, repo, pr_number, agent_name)
      [_, "status"] -> status(ctx, repo, pr_number)
      _ -> reply(ctx, repo, pr_number, unknown_help())
    end
  end

  defp enable_agent(ctx, repo, pr_number, agent_name) do
    normalized = String.downcase(agent_name)

    if Cache.get(normalized) do
      PerRepo.enable_agent(repo, normalized)
      reply(ctx, repo, pr_number, "Agent `#{normalized}` is now **enabled** for this repo.")
    else
      reply(ctx, repo, pr_number, unknown_agent(normalized))
    end
  end

  defp disable_agent(ctx, repo, pr_number, agent_name) do
    normalized = String.downcase(agent_name)

    if Cache.get(normalized) do
      PerRepo.disable_agent(repo, normalized)
      reply(ctx, repo, pr_number, "Agent `#{normalized}` is now **disabled** for this repo.")
    else
      reply(ctx, repo, pr_number, unknown_agent(normalized))
    end
  end

  defp status(ctx, repo, pr_number) do
    overrides = PerRepo.overrides(repo)

    message = """
    **Bugseeker status** for `#{repo.owner}/#{repo.name}`
    - Bot enabled: #{if PerRepo.enabled?(repo), do: "yes", else: "no"}
    - Active agents: #{Enum.join(PerRepo.active_agent_names(repo), ", ")}
    - Inline threshold: `#{PerRepo.min_inline_severity(repo)}`
    - Runtime overrides: #{if overrides == %{}, do: "none (config defaults)", else: inspect(overrides)}
    """

    reply(ctx, repo, pr_number, message)
  end

  defp reply(ctx, repo, pr_number, body) do
    mention = if ctx[:user], do: "@#{ctx[:user]} ", else: ""

    case Clients.github().post_issue_comment(repo, pr_number, mention <> body) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("command reply failed", reason: inspect(reason))
    end
  end

  defp unknown_agent(agent_name) do
    "Unknown agent `#{agent_name}`. Available agents: #{Enum.join(Cache.all_names(), ", ")}."
  end

  defp unknown_help do
    """
    I did not understand that command. Available commands:
    - `/bugseeker enable-agent <name>`
    - `/bugseeker disable-agent <name>`
    - `/bugseeker status`
    """
  end
end
