defmodule Codeseeker.Jobs.FetchDiffJobTest do
  use Codeseeker.RepoCase, async: false

  import Mox

  alias Codeseeker.Github.Client.Mock, as: GithubMock
  alias Codeseeker.Jobs.FetchDiffJob
  alias Codeseeker.Reviews

  setup do
    # No Oban cron/duplicate checks; each test uses a unique head_sha.
    :ok
  end

  defp args(head_sha) do
    %{
      "repo" => %{
        "github_repo_id" => 100,
        "owner" => "acme-internal",
        "name" => "web-frontend",
        "installation_id" => 42
      },
      "pr_number" => 12,
      "head_sha" => head_sha,
      "base_sha" => "base0000"
    }
  end

  defp ts_file do
    %{
      path: "src/api.ts",
      patch: "@@ -1 +1 @@",
      additions: 1,
      deletions: 0,
      status: "modified",
      sha: "f1"
    }
  end

  test "happy path: creates a run, stores guidelines, enqueues one job per file" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 ->
      {:ok, [ts_file(), %{ts_file() | path: "main.go"}]}
    end)

    expect(GithubMock, :get_raw_contents, fn _repo, _path, _ref ->
      {:ok, "Always use transactions."}
    end)

    sha = unique_sha("head")
    assert {:ok, %{files: 2}} = perform(FetchDiffJob, args(sha))

    pr = Reviews.find_pr_review(100, 12, sha)
    assert pr.status == "processing"
    assert pr.total_files == 2
    assert pr.guidelines == "Always use transactions."

    enqueued = enqueued(Codeseeker.Jobs.ReviewFileJob)
    assert length(enqueued) == 2
  end

  test "no patchable files -> finalizes completed without enqueueing reviews" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 ->
      {:ok,
       [
         %{
           path: "package-lock.json",
           patch: "{}",
           additions: 1,
           deletions: 0,
           status: "modified",
           sha: "f"
         }
       ]}
    end)

    sha = unique_sha("head")
    assert {:ok, %{files: 0}} = perform(FetchDiffJob, args(sha))

    pr = Reviews.find_pr_review(100, 12, sha)
    assert pr.status == "completed"
    assert enqueued(Codeseeker.Jobs.ReviewFileJob) == []
  end

  test "repo disabled -> discarded, nothing enqueued" do
    repo = %{owner: "disabled-owner", name: "off-repo", installation_id: 1}
    Codeseeker.PerRepo.set_enabled(repo, false)

    args = %{
      "repo" => %{
        "github_repo_id" => 200,
        "owner" => "disabled-owner",
        "name" => "off-repo",
        "installation_id" => 1
      },
      "pr_number" => 1,
      "head_sha" => unique_sha("head"),
      "base_sha" => "b"
    }

    assert perform(FetchDiffJob, args) == :discard
    assert enqueued(Codeseeker.Jobs.ReviewFileJob) == []
  end

  test "redelivery of the same head_sha is discarded (idempotent)" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 -> {:ok, [ts_file()]} end)
    expect(GithubMock, :get_raw_contents, fn _repo, _path, _ref -> {:error, :not_found} end)

    sha = unique_sha("head")

    assert {:ok, _} = perform(FetchDiffJob, args(sha))
    # GitHub redelivers the same webhook:
    assert perform(FetchDiffJob, args(sha)) == :discard
    assert length(enqueued(Codeseeker.Jobs.ReviewFileJob)) == 1
  end

  test "github list error raises so Oban retries" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 ->
      {:error,
       %Codeseeker.Github.Error{
         status: 500,
         reason: :api_error,
         retryable?: true,
         message: "boom"
       }}
    end)

    assert_raise RuntimeError, ~r/list_pr_files failed/, fn ->
      perform(FetchDiffJob, args(unique_sha("head")))
    end
  end
end
