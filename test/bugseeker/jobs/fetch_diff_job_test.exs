defmodule Bugseeker.Jobs.FetchDiffJobTest do
  use Bugseeker.RepoCase, async: false

  import Mox

  alias Bugseeker.Github.Client.Mock, as: GithubMock
  alias Bugseeker.Jobs.AgentJob
  alias Bugseeker.Jobs.FetchDiffJob
  alias Bugseeker.Reviews

  @agents Bugseeker.Agents.Cache.all_names()
  @agent_count length(@agents)

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

  test "happy path: stores guidelines + files, enqueues one AgentJob per agent" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 ->
      {:ok, [ts_file(), %{ts_file() | path: "main.go"}]}
    end)

    stub(GithubMock, :get_raw_contents, fn _repo, path, _ref ->
      case path do
        "docs/engineering-guidelines.md" -> {:ok, "Always use transactions."}
        _ -> {:error, :not_found}
      end
    end)

    sha = unique_sha("head")
    assert {:ok, %{agents: @agent_count}} = perform(FetchDiffJob, args(sha))

    pr = Reviews.find_pr_review(100, 12, sha)
    assert pr.status == "processing"
    assert pr.total_files == @agent_count
    assert pr.guidelines == "Always use transactions."
    assert pr.files |> length() == 2
    assert Enum.map(pr.files, & &1["path"]) == ["src/api.ts", "main.go"]

    assert length(enqueued(AgentJob)) == @agent_count
  end

  test "no patchable files -> finalizes completed without enqueueing agents" do
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
    assert {:ok, %{agents: 0}} = perform(FetchDiffJob, args(sha))

    pr = Reviews.find_pr_review(100, 12, sha)
    assert pr.status == "completed"
    assert enqueued(AgentJob) == []
  end

  test "repo disabled -> discarded, nothing enqueued" do
    repo = %{owner: "disabled-owner", name: "off-repo", installation_id: 1}
    Bugseeker.PerRepo.set_enabled(repo, false)

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
    assert enqueued(AgentJob) == []
  end

  test "repo .bugseeker.yml agents override PerRepo defaults" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 -> {:ok, [ts_file()]} end)

    stub(GithubMock, :get_raw_contents, fn _repo, path, _ref ->
      case path do
        ".bugseeker.yml" -> {:ok, "agents:\n  - nestjs_security\n"}
        _ -> {:error, :not_found}
      end
    end)

    sha = unique_sha("head")
    assert {:ok, %{agents: 1}} = perform(FetchDiffJob, args(sha))

    enqueued_agents =
      enqueued(AgentJob) |> Enum.map(& &1.args["agent"]) |> Enum.sort()

    assert enqueued_agents == ["nestjs_security"]

    pr = Reviews.find_pr_review(100, 12, sha)
    assert pr.total_files == 1
  end

  test "repo .bugseeker.yml min_inline_severity is stored on the run" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 -> {:ok, [ts_file()]} end)

    stub(GithubMock, :get_raw_contents, fn _repo, path, _ref ->
      case path do
        ".bugseeker.yml" -> {:ok, "min_inline_severity: critical\n"}
        _ -> {:error, :not_found}
      end
    end)

    sha = unique_sha("head")
    assert {:ok, %{agents: @agent_count}} = perform(FetchDiffJob, args(sha))

    pr = Reviews.find_pr_review(100, 12, sha)
    assert pr.min_inline_severity == "CRITICAL"
  end

  test "redelivery of the same head_sha is discarded (idempotent)" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 -> {:ok, [ts_file()]} end)
    stub(GithubMock, :get_raw_contents, fn _repo, _path, _ref -> {:error, :not_found} end)

    sha = unique_sha("head")

    assert {:ok, _} = perform(FetchDiffJob, args(sha))
    # GitHub redelivers the same webhook:
    assert perform(FetchDiffJob, args(sha)) == :discard
    assert length(enqueued(AgentJob)) == @agent_count
  end

  test "github list error raises so Oban retries" do
    expect(GithubMock, :list_pr_files, fn _repo, 12 ->
      {:error,
       %Bugseeker.Github.Error{
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
