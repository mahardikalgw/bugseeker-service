defmodule Codeseeker.CoordinatorTest do
  use ExUnit.Case, async: false

  import Mox

  alias Codeseeker.CoordinatorSup
  alias Codeseeker.Llm.DeepSeek.Mock, as: LlmMock
  alias Codeseeker.Github.Client.Mock, as: GithubMock

  setup do
    Mox.set_mox_global()
    Mox.verify_on_exit!()

    # Stop any coordinator left running by a previous test so it cannot
    # consume mocks of the current test.
    Codeseeker.CoordinatorSup
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Codeseeker.CoordinatorSup, pid)

      _ ->
        :ok
    end)

    if :ets.whereis(:codeseeker_dedup), do: :ets.delete_all_objects(:codeseeker_dedup)
    :ok
  end

  defp pr(sha) do
    %{
      repo: %{owner: "acme-internal", name: "web-frontend", installation_id: 42},
      pr_number: 12,
      head_sha: sha,
      base_sha: "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
    }
  end

  defp ts_file do
    %{
      path: "src/api.ts",
      patch: "@@ -80,10 +84,10 @@\n+const x = 1;\n",
      additions: 1,
      deletions: 0,
      status: "modified",
      sha: "f1"
    }
  end

  defp go_file do
    %{
      path: "main.go",
      patch: "@@ -1,5 +1,5 @@\n+package main\n",
      additions: 1,
      deletions: 0,
      status: "modified",
      sha: "f2"
    }
  end

  defp lock_file do
    %{
      path: "package-lock.json",
      patch: "{}\n",
      additions: 100,
      deletions: 0,
      status: "modified",
      sha: "f3"
    }
  end

  defp expect_list_files(files) do
    expect(GithubMock, :list_pr_files, fn _repo, 12 -> {:ok, files} end)
  end

  defp expect_guidelines(:not_found) do
    expect(GithubMock, :get_raw_contents, fn _repo, _path, _ref -> {:error, :not_found} end)
  end

  defp expect_guidelines(content) do
    expect(GithubMock, :get_raw_contents, fn _repo, _path, _ref -> {:ok, content} end)
  end

  describe "happy path" do
    test "fetches files, reviews with skills, posts inline + summary" do
      test_pid = self()
      expect_list_files([ts_file(), go_file()])
      expect_guidelines(:not_found)

      expect(LlmMock, :chat, 2, fn prompt ->
        send(test_pid, {:llm_prompt, prompt})

        content =
          if prompt =~ "src/api.ts" do
            ~s({"issues":[{"line":84,"severity":"CRITICAL","category":"security","message":"XSS via innerHTML","recommendation":"Sanitize"}]})
          else
            ~s({"issues":[{"line":3,"severity":"MEDIUM","category":"style","message":"naming"}]})
          end

        {:ok, %{content: content}}
      end)

      expect(GithubMock, :post_review, fn _repo, 12, sha, body, comments ->
        send(test_pid, {:review_posted, sha, body, comments})
        {:ok, %{id: 1}}
      end)

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-happy-001"))

      assert_receive {:llm_prompt, prompt1}, 2_000
      assert_receive {:llm_prompt, prompt2}, 2_000

      prompts = [prompt1, prompt2]
      assert Enum.any?(prompts, &(&1 =~ "## SKILL: typescript" and &1 =~ "src/api.ts"))
      assert Enum.any?(prompts, &(&1 =~ "## SKILL: go" and &1 =~ "main.go"))

      assert_receive {:review_posted, "sha-happy-001", body, comments}, 2_000

      assert [%{path: "src/api.ts", line: 84, side: "RIGHT", body: inline_body}] = comments
      assert inline_body =~ "**[CRITICAL] [security]**"
      assert inline_body =~ "XSS via innerHTML"

      assert body =~ "## 🤖 Codeseeker Review — PR #12"
      assert body =~ "main.go — 1 issue(s)"
      assert body =~ "naming"
    end

    test "includes repo guidelines in the prompt when present" do
      test_pid = self()
      expect_list_files([ts_file()])
      expect_guidelines("Always use transactions.")

      expect(LlmMock, :chat, fn prompt ->
        send(test_pid, {:llm_prompt, prompt})
        {:ok, %{content: ~s({"issues":[]})}}
      end)

      expect(GithubMock, :post_review, fn _repo, 12, _sha, _body, _comments ->
        send(test_pid, :review_posted)
        {:ok, %{}}
      end)

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-guidelines-002"))

      assert_receive {:llm_prompt, prompt}, 2_000
      assert prompt =~ "## TEAM GUIDELINES"
      assert prompt =~ "Always use transactions."
      assert_receive :review_posted, 2_000
    end
  end

  describe "dedup" do
    test "a second identical PR is skipped (one review total)" do
      test_pid = self()
      expect_list_files([ts_file()])
      expect_guidelines(:not_found)
      expect(LlmMock, :chat, fn _ -> {:ok, %{content: ~s({"issues":[]})}} end)

      expect(GithubMock, :post_review, fn _repo, _pr, _sha, _body, _comments ->
        send(test_pid, :review_posted)
        {:ok, %{}}
      end)

      sha = "sha-dedup-003"
      {:ok, _} = CoordinatorSup.start_child(pr(sha))
      {:ok, _} = CoordinatorSup.start_child(pr(sha))

      assert_receive :review_posted, 2_000
      refute_receive :review_posted, 300
    end
  end

  describe "skips" do
    test "repo disabled → nothing fetched, nothing posted" do
      repo = %{owner: "disabled-owner", name: "off-repo", installation_id: 1}
      Codeseeker.PerRepo.set_enabled(repo, false)

      # No expectations: if the coordinator fetches files, Mox fails loudly.
      {:ok, _pid} =
        CoordinatorSup.start_child(%{
          repo: repo,
          pr_number: 1,
          head_sha: "sha-disabled-004",
          base_sha: "b"
        })

      key = {repo.owner, repo.name, 1, "sha-disabled-004"}
      wait_until(fn -> Codeseeker.Dedup.done?(key) end)
      assert Codeseeker.Dedup.done?(key)
    end

    test "all files excluded → no review posted" do
      expect_list_files([lock_file()])

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-excluded-005"))

      key = {"acme-internal", "web-frontend", 12, "sha-excluded-005"}
      wait_until(fn -> Codeseeker.Dedup.done?(key) end)
      refute_receive :review_posted, 100
    end
  end

  describe "failure handling" do
    test "LLM retries on transient errors, then posts" do
      test_pid = self()

      expect_list_files([ts_file()])
      expect_guidelines(:not_found)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      expect(LlmMock, :chat, 2, fn _prompt ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        send(test_pid, {:llm_try, attempt})

        if attempt == 1 do
          {:error, %{type: :rate_limited, message: "slow down"}}
        else
          {:ok,
           %{
             content:
               ~s({"issues":[{"line":84,"severity":"HIGH","category":"bug","message":"ok"}]})
           }}
        end
      end)

      expect(GithubMock, :post_review, fn _repo, _pr, _sha, _body, _comments ->
        send(test_pid, :review_posted)
        {:ok, %{}}
      end)

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-retry-006"))

      assert_receive {:llm_try, 1}, 2_000
      assert_receive {:llm_try, 2}, 2_000
      assert_receive :review_posted, 2_000
    end

    test "LLM failure after retries does not abort the PR" do
      test_pid = self()

      expect_list_files([ts_file()])
      expect_guidelines(:not_found)

      # 2 attempts (test max_retries) — both fail
      expect(LlmMock, :chat, 2, fn _ ->
        {:error, %{type: :api_error, message: "boom"}}
      end)

      expect(GithubMock, :post_review, fn _repo, _pr, _sha, body, comments ->
        send(test_pid, {:review_posted, body, comments})
        {:ok, %{}}
      end)

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-fail-007"))

      assert_receive {:review_posted, body, comments}, 2_000
      assert body =~ "file failed to review"
      assert comments == []
    end

    test "unparseable LLM output is repaired by a follow-up call and issues still post" do
      test_pid = self()

      expect_list_files([ts_file()])
      expect_guidelines(:not_found)

      # First call returns malformed JSON; the coordinator sends a repair
      # prompt and the second call returns valid JSON.
      expect(LlmMock, :chat, 2, fn prompt ->
        send(test_pid, {:llm_prompt, prompt})

        if prompt =~ "REPAIR" do
          {:ok,
           %{
             content:
               ~s({"issues":[{"line":84,"severity":"HIGH","category":"bug","message":"after repair"}]})
           }}
        else
          {:ok, %{content: "this is not json"}}
        end
      end)

      expect(GithubMock, :post_review, fn _repo, _pr, _sha, _body, comments ->
        send(test_pid, {:review_posted, comments})
        {:ok, %{}}
      end)

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-repair-009"))

      assert_receive {:llm_prompt, first}, 2_000
      refute first =~ "REPAIR"

      assert_receive {:llm_prompt, repair}, 2_000
      assert repair =~ "REPAIR"

      assert_receive {:review_posted, comments}, 2_000
      assert [%{body: inline_body}] = comments
      assert inline_body =~ "after repair"
    end

    test "unparseable output that cannot be repaired still completes the PR" do
      test_pid = self()

      expect_list_files([ts_file()])
      expect_guidelines(:not_found)

      expect(LlmMock, :chat, fn _ ->
        {:ok, %{content: "not json at all"}}
      end)

      expect(LlmMock, :chat, fn _ ->
        {:ok, %{content: "still not json"}}
      end)

      expect(GithubMock, :post_review, fn _repo, _pr, _sha, body, comments ->
        send(test_pid, {:review_posted, body, comments})
        {:ok, %{}}
      end)

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-repair-fail-010"))

      assert_receive {:review_posted, body, comments}, 2_000
      assert comments == []
      assert body =~ "## 🤖 Codeseeker Review"
    end

    test "422 invalid_line demotes all inline comments and reposts without them" do
      test_pid = self()

      expect_list_files([ts_file()])
      expect_guidelines(:not_found)

      expect(LlmMock, :chat, fn _ ->
        {:ok,
         %{
           content:
             ~s({"issues":[{"line":84,"severity":"CRITICAL","category":"security","message":"XSS"}]})
         }}
      end)

      expect(GithubMock, :post_review, 2, fn _repo, _pr, _sha, _body, comments ->
        send(test_pid, {:post_attempt, comments})

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

      {:ok, _pid} = CoordinatorSup.start_child(pr("sha-422-008"))

      assert_receive {:post_attempt, [_]}, 2_000
      assert_receive {:post_attempt, []}, 2_000
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    unless fun.() do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        wait_until(fun, timeout)
      end
    end
  end
end
