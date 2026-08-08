defmodule Codeseeker.Skills.Registry do
  @moduledoc """
  Maps a file extension to the skill that should review it, falling back
  to the generic skill for unknown extensions. Also composes prompts and
  applies a skill's severity bias to parsed issues.

  Pure module — no side effects.
  """

  alias Codeseeker.Llm.Prompt
  alias Codeseeker.Reviews.Issue
  alias Codeseeker.Skills.{Cache, Skill}

  @doc """
  Resolves the skill for a file path (or extension with a leading dot).

  Unknown extensions and missing skill files fall back to the generic
  skill.
  """
  @spec resolve(String.t()) :: Skill.t()
  def resolve(file_path) do
    ext = Path.extname(file_path)
    manifest = Application.get_env(:codeseeker, :skills_manifest, %{})
    name = Map.get(manifest, ext)
    Cache.get(name) || Cache.get(Application.get_env(:codeseeker, :fallback_skill, "generic"))
  end

  @doc """
  Composes the final prompt for one file: base prompt + skill content +
  optional team guidelines + diff. See `Codeseeker.Llm.Prompt`.
  """
  @spec prompt_for(Skill.t(), map(), String.t() | nil) :: String.t()
  def prompt_for(skill, file, guidelines \\ nil) do
    Prompt.build(skill, file, guidelines)
  end

  @doc """
  Applies the skill's `severity_bias` to issues: when an issue's message
  contains one of the bias keys, its severity is raised to the biased
  value (never lowered). Keys are matched case-insensitively as substrings.
  """
  @spec apply_bias([Issue.t()], Skill.t()) :: [Issue.t()]
  def apply_bias(issues, %Skill{severity_bias: bias}) when map_size(bias) > 0 do
    Enum.map(issues, &apply_bias_one(&1, bias))
  end

  def apply_bias(issues, _skill), do: issues

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
