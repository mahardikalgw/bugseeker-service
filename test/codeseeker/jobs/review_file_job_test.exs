defmodule Codeseeker.Jobs.ReviewFileJobTest do
  use Codeseeker.RepoCase, async: false

  import Mox

  alias Codeseeker.Github.Client.Mock, as: GithubMock
  alias Codeseeker.Jobs.ReviewFileJob
  alias Codeseeker.Llm.DeepSeek.Mock, as: LlmMock
  alias Codeseeker.Reviews

  defp file(overrides \\ %{}) do
    Map.merge(
      %{
        "path" => "src/api.ts",
        "patch" => "@@ -80,10 +84,10 @@\n+const x = 1;\n",
        "additions" => 1,
        "deletions" => 0,
        "status" => "modified",
        "sha" => "f1"
      },
      overrides
    )
  end

  test "parses LLM output and persists issues" do
    pr_review = insert_pr_review!(total_files: 1)

    expect(LlmMock, :chat, fn prompt ->
      assert prompt =~ "## SKILL: typescript"
      assert prompt =~ "src/api.ts"

      {:ok,
       %{
         content:
           ~s({"issues":[{"line":84,"severity":"CRITICAL","category":"security","message":"XSS","recommendation":"Fix"}]})
       }}
    end)

    assert {:ok, %{issues: 1}} =
             perform(ReviewFileJob, %{"pr_review_id" => pr_review.id, "file" => file()})

    assert length(Reviews.issues_for(pr_review)) == 1
  end

  test "includes repo guidelines in the prompt when present" do
    pr_review = insert_pr_review!(total_files: 1, guidelines: "Always use transactions.")

    expect(LlmMock, :chat, fn prompt ->
      assert prompt =~ "TEAM GUIDELINES"
      assert prompt =~ "Always use transactions."
      {:ok, %{content: ~s({"issues":[]})}}
    end)

    assert {:ok, %{issues: 0}} =
             perform(ReviewFileJob, %{"pr_review_id" => pr_review.id, "file" => file()})
  end

  test "unparseable LLM output is skipped without retrying" do
    pr_review = insert_pr_review!(total_files: 1)

    expect(LlmMock, :chat, fn _ ->
      {:ok, %{content: "not json at all"}}
    end)

    assert {:ok, %{issues: 0, skipped: true}} =
             perform(ReviewFileJob, %{"pr_review_id" => pr_review.id, "file" => file()})
  end

  test "LLM error returns {:error} for Oban retry (not counted as done)" do
    pr_review = insert_pr_review!(total_files: 1)

    expect(LlmMock, :chat, fn _ ->
      {:error, %{type: :rate_limited, message: "slow down"}}
    end)

    assert {:error, %{type: :rate_limited}} =
             perform(ReviewFileJob, %{"pr_review_id" => pr_review.id, "file" => file()})

    pr = Repo.get(Codeseeker.Reviews.PrReview, pr_review.id)
    assert pr.files_reviewed == 0
  end

  test "last file to finish enqueues the aggregate job" do
    pr_review = insert_pr_review!(total_files: 1)

    expect(LlmMock, :chat, fn _ ->
      {:ok, %{content: ~s({"issues":[]})}}
    end)

    assert {:ok, _} = perform(ReviewFileJob, %{"pr_review_id" => pr_review.id, "file" => file()})

    assert [%Oban.Job{worker: "Codeseeker.Jobs.AggregateReviewJob"}] =
             enqueued(Codeseeker.Jobs.AggregateReviewJob)
  end

  test "non-last files do not enqueue the aggregate job" do
    pr_review = insert_pr_review!(total_files: 2)

    expect(LlmMock, :chat, fn _ ->
      {:ok, %{content: ~s({"issues":[]})}}
    end)

    assert {:ok, _} = perform(ReviewFileJob, %{"pr_review_id" => pr_review.id, "file" => file()})
    assert enqueued(Codeseeker.Jobs.AggregateReviewJob) == []
  end

  test "github client is not used by this job" do
    pr_review = insert_pr_review!(total_files: 1)

    expect(LlmMock, :chat, fn _ ->
      {:ok, %{content: ~s({"issues":[]})}}
    end)

    assert {:ok, _} = perform(ReviewFileJob, %{"pr_review_id" => pr_review.id, "file" => file()})
  end
end
