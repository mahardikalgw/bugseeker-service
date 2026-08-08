defmodule Bugseeker.Agents do
  @moduledoc """
  Helpers for review agents. The `apply_bias/2` function raises issue
  severity per an agent's `severity_bias` (from the optional `## Severity`
  section of its Markdown file).
  """

  alias Bugseeker.Agents.Agent
  alias Bugseeker.Reviews.Issue

  @doc """
  Applies an agent's `severity_bias` to issues: when an issue's message
  contains one of the bias keys, its severity is raised to the biased value
  (never lowered). Keys are matched case-insensitively as substrings.
  """
  @spec apply_bias([Issue.t()], Agent.t()) :: [Issue.t()]
  def apply_bias(issues, %Agent{severity_bias: bias}) when map_size(bias) > 0 do
    Enum.map(issues, &apply_bias_one(&1, bias))
  end

  def apply_bias(issues, _agent), do: issues

  defp apply_bias_one(%Issue{message: message} = issue, bias) do
    lower = String.downcase(message)

    biased =
      bias
      |> Enum.filter(fn {key, _severity} -> String.contains?(lower, key) end)
      |> Enum.map(fn {_key, severity} -> severity end)
      |> Enum.reduce(nil, fn severity, acc ->
        if is_nil(acc) or Issue.severity_rank(severity) < Issue.severity_rank(acc),
          do: severity,
          else: acc
      end)

    case biased do
      nil -> issue
      severity when severity != issue.severity -> %{issue | severity: severity}
      _ -> issue
    end
  end
end
