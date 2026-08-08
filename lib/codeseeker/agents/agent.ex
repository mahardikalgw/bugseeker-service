defmodule Codeseeker.Agents.Agent do
  @moduledoc """
  A review agent is a README-style Markdown instruction document that the
  bot reads and passes to the LLM as the review guidelines for one
  cross-language or framework-specific dimension.

  Optional sections:
    * `## File types` — extensions this agent applies to (e.g. `.tsx`).
      When set, the agent only runs if a PR touches a matching file.
    * `## Severity` — parsed into `severity_bias`; matching issues are raised.

  The remaining content is kept verbatim as `content` and appended to the
  prompt.
  """

  defstruct [:name, :path, :content, :file_extensions, :severity_bias]

  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t(),
          content: String.t(),
          file_extensions: [String.t()],
          severity_bias: %{optional(String.t()) => String.t()}
        }

  @file_types_heading ~r/^##\s+File\s+Types\s*$/i
  @severity_heading ~r/^##\s+Severity\s*$/i
  @file_type_line ~r/^\s*-\s*(\.\w+)\s*$/i
  @severity_line ~r/^\s*-\s*(.+?)\s*:\s*(CRITICAL|HIGH|MEDIUM|LOW|INFO)\s*$/i

  @doc """
  Loads and parses an agent Markdown file. `name` is derived from the path
  unless given explicitly.
  """
  @spec load(String.t(), String.t() | nil) :: t()
  def load(path, name \\ nil) do
    content = File.read!(path)

    %{content: content, file_extensions: file_extensions, severity_bias: severity_bias} =
      parse(content)

    %__MODULE__{
      name: name || Path.basename(path, ".md"),
      path: path,
      content: content,
      file_extensions: file_extensions,
      severity_bias: severity_bias
    }
  end

  @doc """
  Splits an agent file into its instruction content (everything except the
  `## File types` and `## Severity` blocks) and the parsed metadata.
  """
  @spec parse(String.t()) :: %{
          content: String.t(),
          file_extensions: [String.t()],
          severity_bias: %{optional(String.t()) => String.t()}
        }
  def parse(content) do
    lines = String.split(content, "\n")

    {content_lines, file_extensions, severity_bias} =
      Enum.reduce(lines, {%{mode: :content, out: []}, [], %{}}, fn line, {acc, exts, bias} ->
        cond do
          Regex.match?(@file_types_heading, line) ->
            {%{acc | mode: :file_types}, exts, bias}

          Regex.match?(@severity_heading, line) ->
            {%{acc | mode: :severity}, exts, bias}

          acc.mode == :file_types and is_ext(line) ->
            {acc, [normalize_ext(line) | exts], bias}

          acc.mode == :severity and Regex.match?(@severity_line, line) ->
            {acc, exts, Map.merge(bias, severity_pair(line))}

          acc.mode == :content ->
            {%{acc | out: [line | acc.out]}, exts, bias}

          true ->
            {acc, exts, bias}
        end
      end)

    %{
      content: content_lines.out |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing(),
      file_extensions: Enum.reverse(file_extensions),
      severity_bias: severity_bias
    }
  end

  defp is_ext(line), do: Regex.match?(@file_type_line, line)

  defp normalize_ext(line) do
    case Regex.run(@file_type_line, line) do
      [_, ext] -> String.downcase(ext)
      _ -> nil
    end
  end

  defp severity_pair(line) do
    case Regex.run(@severity_line, line) do
      [_, key, severity] -> %{String.downcase(key) => String.upcase(severity)}
      _ -> %{}
    end
  end
end
