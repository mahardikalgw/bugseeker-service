defmodule Codeseeker.CommandsTest do
  use ExUnit.Case, async: false

  import Mox

  alias Codeseeker.Commands
  alias Codeseeker.Github.Client.Mock, as: GithubMock

  setup do
    Mox.set_mox_global()
    Mox.verify_on_exit!()
    :ok
  end

  defp repo, do: %{owner: "acme-internal", name: "web-frontend", installation_id: 42}

  describe "run/1" do
    test "enable-skill enables a valid skill and replies" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Commands.run(%{
        repo: repo(),
        pr_number: 1,
        comment: "/codeseeker enable-skill go",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "@dev "
      assert body =~ "Skill `go` is now **enabled**"
      assert "go" in Codeseeker.PerRepo.active_skill_names(repo())
    end

    test "disable-skill disables a valid skill" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Codeseeker.PerRepo.enable_skill(repo(), "go")

      Commands.run(%{
        repo: repo(),
        pr_number: 1,
        comment: "/codeseeker disable-skill go",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "Skill `go` is now **disabled**"
      refute "go" in Codeseeker.PerRepo.active_skill_names(repo())
    end

    test "unknown skill lists available skills" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Commands.run(%{
        repo: repo(),
        pr_number: 1,
        comment: "/codeseeker enable-skill cobol",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "Unknown skill `cobol`"
      assert body =~ "typescript"
    end

    test "status reports enabled state, skills and threshold" do
      test_pid = self()

      expect(GithubMock, :post_issue_comment, fn _repo, _pr, body ->
        send(test_pid, {:reply, body})
        {:ok, %{}}
      end)

      Commands.run(%{repo: repo(), pr_number: 1, comment: "/codeseeker status", user: "dev"})

      assert_receive {:reply, body}, 1_000
      assert body =~ "Bot enabled: yes"
      assert body =~ "Active skills"
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
        comment: "/codeseeker do-the-thing",
        user: "dev"
      })

      assert_receive {:reply, body}, 1_000
      assert body =~ "Available commands"
    end
  end
end
