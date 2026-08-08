defmodule Codeseeker.Reviews.AggregatorTest do
  use ExUnit.Case, async: true

  alias Codeseeker.Reviews.Aggregator, as: Review
  alias Codeseeker.Reviews.Issue

  defp issue(path, line, severity, category, message) do
    %Issue{
      file_path: path,
      line: line,
      severity: severity,
      category: category,
      message: message,
      agent: "security"
    }
  end

  defp pr(overrides \\ %{}) do
    %{
      repo: %{owner: "acme", name: "app", installation_id: 1},
      pr_number: 12,
      head_sha: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c",
      base_sha: "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
    }
    |> Map.merge(Map.new(overrides))
  end

  defp patches, do: %{"src/api.ts" => "@@ -80,10 +84,10 @@\n+new line\n"}

  describe "aggregate/5" do
    test "splits CRITICAL/HIGH to inline comments and the rest to summary" do
      issues = [
        issue("src/api.ts", 84, "CRITICAL", "security", "XSS risk"),
        issue("src/api.ts", 85, "HIGH", "bug", "null deref"),
        issue("src/api.ts", 86, "MEDIUM", "style", "naming"),
        issue("src/api.ts", 87, "LOW", "style", "nitpick")
      ]

      result = Review.aggregate(issues, patches(), [], [], pr())

      assert [c1, c2] = result.inline
      assert c1.line == 84 and c1.side == "RIGHT" and c1.path == "src/api.ts"
      assert c1.body =~ "XSS risk"
      assert c2.line == 85

      assert result.summary_body =~ "## 🤖 Codeseeker Review — PR #12"
      assert result.summary_body =~ "src/api.ts — 2 issue(s)"
      assert result.summary_body =~ "naming"
      assert result.summary_body =~ "nitpick"
      refute result.summary_body =~ "XSS risk"
      assert result.demoted == []
    end

    test "demotes inline candidates whose line is outside the hunks" do
      issues = [
        issue("src/api.ts", 999, "CRITICAL", "security", "line way off"),
        issue("src/api.ts", 84, "CRITICAL", "security", "valid line")
      ]

      result = Review.aggregate(issues, patches(), [], [], pr())

      assert [comment] = result.inline
      assert comment.line == 84
      assert [demoted] = result.demoted
      assert demoted.line == 999
      assert result.summary_body =~ "**[inline failed — invalid line]**"
      assert result.summary_body =~ "line way off"
    end

    test "demotes nil-line issues to the summary" do
      issues = [issue("src/api.ts", nil, "CRITICAL", "arch", "cross-file concern")]
      result = Review.aggregate(issues, patches(), [], [], pr())
      assert result.inline == []
      assert result.summary_body =~ "cross-file concern"
    end

    test "zero issues and no notes produce an empty body (caller posts default)" do
      result = Review.aggregate([], patches(), [], [], pr())
      assert result.inline == []
      assert result.summary_body == ""
    end

    test "includes skipped files and warnings in the notes section" do
      skipped = [%{path: "package-lock.json", reason: "excluded pattern"}]
      warnings = ["file failed to review: timeout"]

      result = Review.aggregate([], patches(), skipped, warnings, pr())

      assert result.summary_body =~ "### Notes"
      assert result.summary_body =~ "Skipped: package-lock.json (excluded pattern)"
      assert result.summary_body =~ "file failed to review: timeout"
    end

    test "notes section is omitted when empty" do
      result = Review.aggregate([], patches(), [], [], pr())
      refute result.summary_body =~ "### Notes"
    end

    test "respects a per-repo inline threshold of CRITICAL" do
      repo = %{owner: "threshold-owner", name: "strict-repo", installation_id: 1}
      Codeseeker.PerRepo.set_min_inline_severity(repo, "CRITICAL")

      issues = [
        issue("src/api.ts", 84, "HIGH", "bug", "high severity")
      ]

      result = Review.aggregate(issues, patches(), [], [], pr(repo: repo))

      assert result.inline == []
      assert result.summary_body =~ "high severity"
    end
  end
end
