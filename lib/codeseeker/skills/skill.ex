defmodule Codeseeker.Skills.Skill do
  @moduledoc """
  A skill is a README-style Markdown instruction document that the bot
  reads and passes to the LLM as review guidelines for one language.

  The optional `## Severity` section is parsed into `severity_bias`:
  `%{"xss" => "CRITICAL", ...}`. All remaining content is kept verbatim
  as `content` and appended to the prompt.
  """

  defstruct [:name, :path, :content, :severity_bias]

  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t(),
          content: String.t(),
          severity_bias: %{optional(String.t()) => String.t()}
        }

  @severity_heading ~r/^##\s+Severity\s*$/i
  @severity_line ~r/^\s*-\s*(.+?)\s*:\s*(CRITICAL|HIGH|MEDIUM|LOW|INFO)\s*$/i

  @doc """
  Loads and parses a skill Markdown file. `name` is derived from the
  filename unless given explicitly.
  """
  @spec load(String.t(), String.t() | nil) :: t()
  def load(path, name \\ nil) do
    content = File.read!(path)
    {content, severity_bias} = parse(content)

    %__MODULE__{
      name: name || Path.basename(path, ".md"),
      path: path,
      content: content,
      severity_bias: severity_bias
    }
  end

  @doc """
  Splits a skill file into the instruction content (everything except the
  `## Severity` block) and the parsed `severity_bias` map.
  """
  @spec parse(String.t()) :: {String.t(), %{optional(String.t()) => String.t()}}
  def parse(content) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &Regex.match?(@severity_heading, &1)) do
      nil ->
        {content, %{}}

      index ->
        {instructions, severity_lines} = Enum.split(lines, index)
        bias = parse_severity_lines(severity_lines)
        {Enum.join(instructions, "\n") |> String.trim_trailing(), bias}
    end
  end

  defp parse_severity_lines(lines) do
    lines
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(@severity_line, line) do
        [_, key, severity] -> Map.put(acc, String.downcase(key), String.upcase(severity))
        _ -> acc
      end
    end)
  end
end
