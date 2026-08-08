defmodule Bugseeker.Jobs.AgentJobTest do
  use Bugseeker.RepoCase, async: false

  import Mox

  alias Bugseeker.Agents.Cache
  alias Bugseeker.Jobs.AgentJob
  alias Bugseeker.Llm.DeepSeek.Mock, as: LlmMock
  alias Bugseeker.Reviews

  defp pr_review(overrides \\ %{}) do
    insert_pr_review!(
      Map.merge(
        %{
          total_files: 1,
          files: [
            %{
              "path" => "src/api.ts",
              "patch" => "@@ -80,10 +84,10 @@\n+const userInput = req.query.x;\n",
              "additions" => 1,
              "deletions" => 0,
              "status" => "modified",
              "sha" => "f1"
            }
          ]
        },
        Map.new(overrides)
      )
    )
  end

  test "parses issues with file_path and persists them, attributing the agent" do
    pr_review = pr_review()

    expect(LlmMock, :chat, fn prompt ->
      assert prompt =~ "## AGENT: react_js_security"
      assert prompt =~ "# Agent: React JS / Security"
      assert prompt =~ "src/api.ts"

      {:ok,
       %{
         content:
           ~s({"issues":[{"file_path":"src/api.ts","line":84,"severity":"CRITICAL","category":"security","message":"SQL injection","recommendation":"Use parameters"}]})
       }}
    end)

    assert {:ok, %{issues: 1}} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})

    assert [issue] = Reviews.issues_for(pr_review)
    assert issue.file_path == "src/api.ts"
    assert issue.severity == "CRITICAL"
    assert issue.agent == "react_js_security"
  end

  test "includes repo guidelines in the agent prompt when present" do
    pr_review = pr_review(guidelines: "Always use transactions.")

    expect(LlmMock, :chat, fn prompt ->
      assert prompt =~ "TEAM GUIDELINES"
      assert prompt =~ "Always use transactions."
      {:ok, %{content: ~s({"issues":[]})}}
    end)

    assert {:ok, %{issues: 0}} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})
  end

  test "unparseable LLM output is skipped without retrying" do
    pr_review = pr_review()

    expect(LlmMock, :chat, fn _ -> {:ok, %{content: "not json at all"}} end)

    assert {:ok, %{issues: 0, skipped: true}} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})
  end

  test "LLM error returns {:error} for Oban retry (not counted as done)" do
    pr_review = pr_review()

    expect(LlmMock, :chat, fn _ -> {:error, %{type: :rate_limited, message: "slow down"}} end)

    assert {:error, %{type: :rate_limited}} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})

    pr = Repo.get(Bugseeker.Reviews.PrReview, pr_review.id)
    assert pr.files_reviewed == 0
  end

  test "last agent to finish enqueues the aggregate job" do
    pr_review = pr_review()

    expect(LlmMock, :chat, fn _ -> {:ok, %{content: ~s({"issues":[]})}} end)

    assert {:ok, _} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})

    assert [%Oban.Job{worker: "Bugseeker.Jobs.AggregateReviewJob"}] =
             enqueued(Bugseeker.Jobs.AggregateReviewJob)
  end

  test "non-last agents do not enqueue the aggregate job" do
    pr_review = pr_review(total_files: 2)

    expect(LlmMock, :chat, fn _ -> {:ok, %{content: ~s({"issues":[]})}} end)

    assert {:ok, _} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})

    assert enqueued(Bugseeker.Jobs.AggregateReviewJob) == []
  end

  test "all configured agents are loaded" do
    names = Cache.all_names()
    assert "react_js_security" in names
    assert "react_js_performance" in names
    assert "react_js_code_quality" in names
    assert "react_js_architecture" in names
    assert "react_js_testing" in names
  end

  test "a framework-specific agent runs only when a matching file is present" do
    # files: src/api.ts
    pr_review = pr_review()

    expect(LlmMock, :chat, fn prompt ->
      assert prompt =~ "## AGENT: react_js_security"
      {:ok, %{content: ~s({"issues":[]})}}
    end)

    assert {:ok, %{issues: 0}} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})
  end

  test "a framework-specific agent is skipped (not run) when no matching file" do
    pr_review = pr_review(files: [%{"path" => "main.go", "patch" => "@@ -1 +1 @@"}])

    # No LLM call expected — a stray call fails the test loudly.
    assert {:ok, %{issues: 0, skipped: true}} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})
  end

  test "skipped specific agents still count toward completion" do
    pr_review =
      pr_review(total_files: 1, files: [%{"path" => "main.go", "patch" => "@@ -1 +1 @@"}])

    assert {:ok, %{issues: 0, skipped: true}} =
             perform(AgentJob, %{"pr_review_id" => pr_review.id, "agent" => "react_js_security"})

    assert [%Oban.Job{worker: "Bugseeker.Jobs.AggregateReviewJob"}] =
             enqueued(Bugseeker.Jobs.AggregateReviewJob)
  end
end
