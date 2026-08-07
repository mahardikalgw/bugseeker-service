defmodule Codeseeker.Hunk do
  @moduledoc """
  Minimal unified-diff parser used to validate that the line numbers
  reported by the LLM fall inside the right-side (new file) hunks of a
  patch, so inline comments are not rejected by the GitHub API.

  It only cares about hunk headers (`@@ -a,b +c,d @@`); the actual line
  content is irrelevant for range computation.
  """

  @hunk_header ~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

  @doc """
  Returns the new-side line ranges of a patch as a list of
  `{start_line, end_line}` tuples, in file order.

  A hunk with a new-side count of zero (pure deletion) yields no range.
  """
  @spec new_line_ranges(String.t() | nil) :: [{pos_integer(), pos_integer()}]
  def new_line_ranges(nil), do: []

  def new_line_ranges(patch) do
    patch
    |> String.split("\n")
    |> Enum.reduce([], &collect_range/2)
    |> Enum.reverse()
    |> Enum.filter(fn {start, finish} -> start <= finish end)
  end

  defp collect_range(line, acc) do
    case Regex.run(@hunk_header, line) do
      [_, start_str] -> [hunk_range(start_str, nil) | acc]
      [_, start_str, count_str] -> [hunk_range(start_str, count_str) | acc]
      _ -> acc
    end
  end

  defp hunk_range(start_str, nil), do: hunk_range(start_str, "1")

  defp hunk_range(start_str, count_str) do
    start = String.to_integer(start_str)
    count = String.to_integer(count_str)
    finish = start + count - 1
    if count > 0, do: {start, finish}, else: {start, start - 1}
  end

  @doc """
  True when `line` falls inside one of the `ranges`.
  """
  @spec line_in_ranges?(pos_integer(), [{pos_integer(), pos_integer()}]) :: boolean()
  def line_in_ranges?(line, ranges) do
    Enum.any?(ranges, fn {start, finish} -> line >= start and line <= finish end)
  end
end
