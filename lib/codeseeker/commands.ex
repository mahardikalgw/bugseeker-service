defmodule Codeseeker.Commands do
  @moduledoc """
  Handles `/codeseeker` commands posted as PR issue comments:

      /codeseeker enable-agent <name>
      /codeseeker disable-agent <name>
      /codeseeker status

  Replies are posted back to the PR as a comment. Runs asynchronously so
  the webhook endpoint can ack immediately.
  """

  require Logger

  alias Codeseeker.{Agents.Cache, Clients, PerRepo}

  @command_regex ~r{^/codeseeker\s+(enable-agent|disable-agent|status)(\s+(\w+))?\s*$}i

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
    **Codeseeker status** for `#{repo.owner}/#{repo.name}`
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
    - `/codeseeker enable-agent <name>`
    - `/codeseeker disable-agent <name>`
    - `/codeseeker status`
    """
  end
end
