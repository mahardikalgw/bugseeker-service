defmodule Codeseeker.Llm.Prompt do
  @moduledoc """
  Composes the final prompt sent to DeepSeek for one file:

  `base_prompt` (output contract) + skill content + optional team
  guidelines + the file diff with new-side line numbers.
  """

  alias Codeseeker.Skills.Skill

  @base_prompt """
  You are a senior code reviewer. Analyze the file diff below and find CLEAR issues:
  bugs, security, performance, or style that violates the rules.
  OUTPUT RULES:
  1. Output ONLY JSON, no markdown fences, no text outside the JSON.
  2. Exact shape: {"issues": [{"line": 12, "severity": "CRITICAL", "category": "security", "message": "...", "recommendation": "..."}]}
  3. severity is one of: CRITICAL, HIGH, MEDIUM, LOW, INFO.
  4. category is one of: security, perf, bug, style, arch.
  5. "line" is the line number in the NEW file (right side of the diff). Use null if unknown.
  6. If there are no issues: {"issues": []}
  7. Only report NEW changes; do not report context/deleted lines that are not part of the change.
  8. Do not repeat the same issue.
  9. Avoid false positives: when in doubt, do not report. Prefer zero issues over wrong ones.
  10. Write message and recommendation in clear English.
  """

  @doc "The fixed output-contract section always present in every prompt."
  def base_prompt, do: @base_prompt

  @doc """
  Builds the final prompt for one file.

  `file` is a map with at least `:path` and `:patch`. `guidelines` is the
  truncated content of the repo's engineering guidelines, or `nil`.
  """
  @spec build(Skill.t(), map(), String.t() | nil) :: String.t()
  def build(%Skill{name: name, content: skill_content}, %{path: path, patch: patch}, guidelines) do
    guidelines_section =
      if guidelines && guidelines != "" do
        "\n\n## TEAM GUIDELINES (from docs/engineering-guidelines.md):\n" <> guidelines
      else
        ""
      end

    @base_prompt <>
      "\n\n## SKILL: " <>
      name <>
      "\n" <>
      skill_content <>
      guidelines_section <>
      "\n\n## FILE: " <>
      path <>
      "\n## DIFF (line numbers are for the NEW file, right side of the diff):\n```diff\n" <>
      (patch || "") <> "\n```"
  end
end
