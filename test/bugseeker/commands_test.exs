defmodule Bugseeker.CommandsTest do
  use ExUnit.Case, async: false

  import Mox

  alias Bugseeker.Commands
  alias Bugseeker.Github.Client.Mock, as: GithubMock

  setup do
    Mox.set_mox_global()
    Mox.verify_on_exit!()
    :ok
  end

  defp repo, do: %{owner: "cmd-test-owner", name: "cmd-repo", installation_id: 42}

  describe "run/1" do
    test "enable-agent enables a valid agent and replies" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Commands.run(%{
        repo: repo(),
        pr_number: 1,
        comment: "/bugseeker enable-agent typescript_security",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "@dev "
      assert body =~ "Agent `typescript_security` is now **enabled**"
      assert "typescript_security" in Bugseeker.PerRepo.active_agent_names(repo())
    end

    test "disable-agent disables a valid agent" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Bugseeker.PerRepo.enable_agent(repo(), "typescript_security")

      Commands.run(%{
        repo: repo(),
        pr_number: 1,
        comment: "/bugseeker disable-agent typescript_security",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "Agent `typescript_security` is now **disabled**"
      refute "typescript_security" in Bugseeker.PerRepo.active_agent_names(repo())
    end

    test "unknown agent lists available agents" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Commands.run(%{
        repo: repo(),
        pr_number: 1,
        comment: "/bugseeker enable-agent cobol",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "Unknown agent `cobol`"
      assert body =~ "typescript_security"
    end

    test "status reports enabled state, agents and threshold" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Commands.run(%{repo: repo(), pr_number: 1, comment: "/bugseeker status", user: "dev"})

      assert_receive {:reply, body}, 1_000
      assert body =~ "Bot enabled: yes"
      assert body =~ "Active agents"
      assert body =~ "Inline threshold: `HIGH`"
    end

    test "unrecognized text replies with help" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Commands.run(%{
        repo: repo(),
        pr_number: 1,
        comment: "/bugseeker do-the-thing",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "Available commands"
    end
  end
end
