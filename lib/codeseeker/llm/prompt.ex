defmodule Codeseeker.Llm.Prompt do
  @moduledoc """
  Composes the final prompt sent to DeepSeek for one review agent.

  `base_prompt` (output contract) + agent content + optional team
  guidelines + the whole PR diff with new-side line numbers.
  """

  alias Codeseeker.Agents.Agent

  @base_prompt """
  You are a senior code reviewer. Analyze the diff below and find CLEAR issues:
  bugs, security, performance, or style that violates the rules.
  OUTPUT RULES:
  1. Output ONLY JSON, no markdown fences, no text outside the JSON.
  2. Exact shape: {"issues": [{"file_path": "src/a.ts", "line": 12, "severity": "CRITICAL", "category": "security", "message": "...", "recommendation": "..."}]}
  3. severity is one of: CRITICAL, HIGH, MEDIUM, LOW, INFO.
  4. category is one of: security, perf, bug, style, arch.
  5. "file_path" must match one of the files in the diff (required).
  6. "line" is the line number in the NEW file (right side of the diff). Use null if unknown.
  7. If there are no issues: {"issues": []}
  8. Only report NEW changes; do not report context/deleted lines that are not part of the change.
  9. Do not repeat the same issue.
  10. Avoid false positives: when in doubt, do not report. Prefer zero issues over wrong ones.
  11. Write message and recommendation in clear English.
  """

  @doc "The fixed output-contract section always present in every prompt."
  def base_prompt, do: @base_prompt

  @doc """
  Builds a prompt for one review agent reviewing the WHOLE PR diff.

  `files` is a list of maps with `:path` and `:patch`. Each agent reports
  issues with a `file_path` so they can be attributed to the right file.
  """
  @spec build_agent(Agent.t(), [map()], String.t() | nil) :: String.t()
  def build_agent(%Agent{name: name, content: content}, files, guidelines) do
    guidelines_section =
      if guidelines && guidelines != "" do
        "\n\n## TEAM GUIDELINES (from docs/engineering-guidelines.md):\n" <> guidelines
      else
        ""
      end

    diff_section =
      files
      |> Enum.reject(&is_nil(&1.patch))
      |> Enum.map_join("\n\n", fn file ->
        "### FILE: #{file.path}\n```diff\n#{file.patch}\n```"
      end)

    @base_prompt <>
      "\n\n## AGENT: " <>
      name <>
      "\n" <>
      content <>
      guidelines_section <>
      "\n\n## DIFF (multiple files; report file_path + new-file line for every issue):\n\n" <>
      diff_section
  end
end
