defmodule Codeseeker.Commands do
  @moduledoc """
  Handles `/codeseeker` commands posted as PR issue comments:

      /codeseeker enable-skill <name>
      /codeseeker disable-skill <name>
      /codeseeker status

  Replies are posted back to the PR as a comment. Runs asynchronously so
  the webhook endpoint can ack immediately.
  """

  require Logger

  alias Codeseeker.{Clients, PerRepo, Skills.Cache}

  @command_regex ~r{^/codeseeker\s+(enable-skill|disable-skill|status)(\s+(\w+))?\s*$}i

  @doc """
  Parses a command body and dispatches it. `ctx` is a map with `:repo`,
  `:pr_number`, `:comment` (the full comment body) and `:user`.
  """
  @spec run(map()) :: :ok
  def run(%{repo: repo, pr_number: pr_number, comment: comment} = ctx) do
    case Regex.run(@command_regex, comment || "") do
      [_, "enable-skill", _, skill_name] -> enable_skill(ctx, repo, pr_number, skill_name)
      [_, "disable-skill", _, skill_name] -> disable_skill(ctx, repo, pr_number, skill_name)
      [_, "status"] -> status(ctx, repo, pr_number)
      _ -> reply(ctx, repo, pr_number, unknown_help())
    end
  end

  defp enable_skill(ctx, repo, pr_number, skill_name) do
    normalized = String.downcase(skill_name)

    if Cache.get(normalized) do
      PerRepo.enable_skill(repo, normalized)
      reply(ctx, repo, pr_number, "Skill `#{normalized}` is now **enabled** for this repo.")
    else
      reply(ctx, repo, pr_number, unknown_skill(normalized))
    end
  end

  defp disable_skill(ctx, repo, pr_number, skill_name) do
    normalized = String.downcase(skill_name)

    if Cache.get(normalized) do
      PerRepo.disable_skill(repo, normalized)
      reply(ctx, repo, pr_number, "Skill `#{normalized}` is now **disabled** for this repo.")
    else
      reply(ctx, repo, pr_number, unknown_skill(normalized))
    end
  end

  defp status(ctx, repo, pr_number) do
    overrides = PerRepo.overrides(repo)

    message = """
    **Codeseeker status** for `#{repo.owner}/#{repo.name}`
    - Bot enabled: #{if PerRepo.enabled?(repo), do: "yes", else: "no"}
    - Active skills: #{Enum.join(PerRepo.active_skill_names(repo), ", ")}
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

  defp unknown_skill(skill_name) do
    "Unknown skill `#{skill_name}`. Available skills: #{Enum.join(Cache.all_names(), ", ")}."
  end

  defp unknown_help do
    """
    I did not understand that command. Available commands:
    - `/codeseeker enable-skill <name>`
    - `/codeseeker disable-skill <name>`
    - `/codeseeker status`
    """
  end
end
