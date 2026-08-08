defmodule Codeseeker.Jobs.AggregateReviewJobTest do
  use Codeseeker.RepoCase, async: false

  import Mox

  alias Codeseeker.Github.Client.Mock, as: GithubMock
  alias Codeseeker.Jobs.AggregateReviewJob
  alias Codeseeker.Reviews

  test "posts the review, marks issues posted, finalizes completed" do
    pr_review = insert_pr_review!(total_files: 1, status: "processing")

    insert_issue(pr_review,
      line: 84,
      severity: "CRITICAL",
      category: "security",
      message: "XSS",
      agent: "security"
    )

    expect(GithubMock, :post_review, fn _repo, 12, sha, body, comments ->
      send(self(), {:posted, sha, body, comments})
      {:ok, %{id: 1}}
    end)

    assert {:ok, _} = perform(AggregateReviewJob, %{"pr_review_id" => pr_review.id})

    assert_receive {:posted, head_sha, body, [comment]}, 1_000
    assert head_sha == pr_review.head_sha
    assert comment.path == "src/api.ts" and comment.line == 84 and comment.side == "RIGHT"
    assert comment.body =~ "XSS"
    assert body =~ "## 🤖 Codeseeker Review"

    pr = Repo.get(Codeseeker.Reviews.PrReview, pr_review.id)
    assert pr.status == "completed"
    assert [issue] = Reviews.issues_for(pr_review)
  end

  test "zero issues still posts a short review and completes" do
    pr_review = insert_pr_review!(total_files: 1, status: "processing")

    expect(GithubMock, :post_review, fn _repo, _pr, _sha, body, comments ->
      send(self(), {:posted, body, comments})
      {:ok, %{}}
    end)

    assert {:ok, _} = perform(AggregateReviewJob, %{"pr_review_id" => pr_review.id})

    assert_receive {:posted, body, comments}, 1_000
    assert comments == []
    assert body =~ "no issues found"
  end

  test "422 invalid_line demotes all inline comments and reposts without them" do
    pr_review = insert_pr_review!(total_files: 1, status: "processing")

    insert_issue(pr_review,
      line: 999,
      severity: "CRITICAL",
      category: "bug",
      message: "bad line",
      agent: "security"
    )

    # No patch is persisted, so lines pass local validation; GitHub rejects them.
    expect(GithubMock, :post_review, 2, fn _repo, _pr, _sha, _body, comments ->
      send(self(), {:attempt, comments})

      if comments == [],
        do: {:ok, %{}},
        else:
          {:error,
           %Codeseeker.Github.Error{
             status: 422,
             reason: :invalid_line,
             retryable?: false,
             message: "line out of hunk"
           }}
    end)

    assert {:ok, _} = perform(AggregateReviewJob, %{"pr_review_id" => pr_review.id})

    assert_receive {:attempt, [_]}, 1_000
    assert_receive {:attempt, []}, 1_000

    pr = Repo.get(Codeseeker.Reviews.PrReview, pr_review.id)
    assert pr.status == "completed"
  end

  defp insert_issue(pr_review, attrs) do
    {:ok, _} =
      Reviews.insert_issues(pr_review, [
        %Codeseeker.Reviews.Issue{
          file_path: "src/api.ts",
          severity: "CRITICAL",
          category: "security",
          message: "XSS",
          agent: "security"
        }
        |> Map.merge(Map.new(attrs))
      ])

    :ok
  end
end
