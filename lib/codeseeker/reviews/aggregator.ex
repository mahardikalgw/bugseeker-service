defmodule Codeseeker.Reviews.Aggregator do
  @moduledoc """
  Pure aggregation logic: splits issues into inline comments vs summary,
  validates line numbers against the diff hunks, and renders the summary
  Markdown body posted to the PR.
  """

  alias Codeseeker.{Hunk, PerRepo}
  alias Codeseeker.Reviews.Issue

  @type review_comment :: %{
          path: String.t(),
          line: pos_integer(),
          side: String.t(),
          body: String.t()
        }

  @type aggregate_result :: %{
          inline: [review_comment()],
          summary_body: String.t(),
          demoted: [Issue.t()]
        }

  @doc """
  Builds the review payload for a PR.

    * `issues` — all issues found across the reviewed files
    * `patches` — `%{file_path => patch}` for hunk validation
    * `skipped` — list of `%{path: path, reason: reason}` maps
    * `warnings` — additional free-form warning strings
    * `pr` — map with `:repo`, `:pr_number`, `:head_sha`, `:agents`
  """
  @spec aggregate(
          [Issue.t()],
          %{optional(String.t()) => String.t() | nil},
          [map()],
          [String.t()],
          map()
        ) ::
          aggregate_result()
  def aggregate(issues, patches, skipped, warnings, pr) do
    # `pr.min_inline_severity` is set from the repo's own `.codeseeker.yml`
    # at intake; it wins over the PerRepo override/global default.
    min_severity =
      Map.get(pr, :min_inline_severity) || PerRepo.min_inline_severity(pr.repo)

    {inline_candidates, summary_issues} =
      Enum.split_with(issues, &Issue.severity_at_least?(&1, min_severity))

    {inline, demoted} =
      inline_candidates
      |> Enum.group_by(& &1.file_path)
      |> Enum.reduce({[], []}, fn {path, file_issues}, {inline, demoted} ->
        patch = Map.get(patches, path)
        ranges = if is_binary(patch), do: Hunk.new_line_ranges(patch), else: nil
        {ok, bad} = Enum.split_with(file_issues, &valid_line?(&1, ranges))
        {ok ++ inline, bad ++ demoted}
      end)

    summary_issues = demoted ++ summary_issues

    %{
      inline: Enum.map(inline, &inline_comment/1),
      summary_body: render_summary(summary_issues, demoted, skipped, warnings, pr),
      demoted: demoted
    }
  end

  # When `ranges` is nil we have no patch for the file (the Oban pipeline does
  # not persist patches), so we defer to GitHub's authoritative validation and
  # treat the line as valid; the 422 fallback demotes invalid ones.
  defp valid_line?(%Issue{line: line}, nil) when is_integer(line), do: true

  defp valid_line?(%Issue{line: line}, ranges) when is_integer(line),
    do: Hunk.line_in_ranges?(line, ranges)

  defp valid_line?(%Issue{}, _ranges), do: false

  defp inline_comment(%Issue{file_path: path, line: line} = issue) do
    %{path: path, line: line, side: "RIGHT", body: issue_body(issue, false)}
  end

  defp issue_body(%Issue{} = issue, inline_failed?) do
    marker = if inline_failed?, do: " **[inline failed — invalid line]**", else: ""

    base = "**[#{issue.severity}] [#{issue.category}]**" <> marker <> " " <> issue.message

    case issue.recommendation do
      rec when is_binary(rec) and rec != "" -> base <> "\n\n**Suggestion:** " <> rec
      _ -> base
    end
  end

  defp render_summary(issues, demoted, skipped, warnings, pr) do
    by_file =
      issues
      |> Enum.group_by(& &1.file_path)
      |> Enum.sort_by(fn {path, _} -> path end)

    agents = Enum.map_join(pr[:agents] || [], ", ", & &1)

    file_sections =
      Enum.map_join(by_file, "\n", fn {path, file_issues} ->
        entries =
          Enum.map_join(file_issues, "\n", fn issue ->
            "  - " <> issue_body(issue, issue in demoted)
          end)

        "### #{path} — #{length(file_issues)} issue(s)\n" <> entries
      end)

    notes =
      Enum.map(skipped, fn %{path: path, reason: reason} -> "- Skipped: #{path} (#{reason})" end) ++
        Enum.map(warnings, &"- #{&1}")

    notes_section =
      if notes == [] do
        ""
      else
        "\n### Notes\n" <> Enum.join(notes, "\n")
      end

    header =
      """
      ## 🤖 Codeseeker Review — PR ##{pr.pr_number}
      Automatic review#{if agents == "", do: "", else: " (agents: #{agents})"} on `#{String.slice(pr.head_sha, 0..7)}`.

      """

    if file_sections == "" and notes_section == "" do
      # Nothing to report: let the caller post a short "no issues" body.
      ""
    else
      header <> file_sections <> notes_section
    end
  end
end
