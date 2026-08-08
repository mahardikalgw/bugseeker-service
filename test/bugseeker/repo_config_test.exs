defmodule Bugseeker.RepoConfigTest do
  use ExUnit.Case, async: false

  import Mox

  alias Bugseeker.Agents.Cache
  alias Bugseeker.Github.Client.Mock, as: GithubMock
  alias Bugseeker.RepoConfig

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp repo, do: %{owner: "acme", name: "api", installation_id: 1}

  describe "parse/1" do
    test "framework bundle expands to all agents with that prefix" do
      config = RepoConfig.parse("agents:\n  - nestjs\n")

      agents = config[:agents]
      assert "nestjs_security" in agents
      assert "nestjs_architecture" in agents
      assert Enum.all?(agents, &String.starts_with?(&1, "nestjs"))
    end

    test "exact agent names pass through" do
      config = RepoConfig.parse("agents:\n  - nestjs_security\n  - react_js_testing\n")

      assert config[:agents] == ["nestjs_security", "react_js_testing"]
    end

    test "mixed bundles and exact names are uniq'd" do
      config = RepoConfig.parse("agents:\n  - nestjs\n  - nestjs_security\n")

      assert Enum.count(config[:agents], &(&1 == "nestjs_security")) == 1
    end

    test "unknown names are dropped" do
      config = RepoConfig.parse("agents:\n  - rails\n")

      assert config[:agents] == nil
    end

    test "min_inline_severity is normalized and validated" do
      assert RepoConfig.parse("min_inline_severity: critical")[:min_inline_severity] == "CRITICAL"
      assert RepoConfig.parse("min_inline_severity: bogus")[:min_inline_severity] == nil
    end

    test "garbage yaml fails open to nil" do
      assert RepoConfig.parse("agents: [") == nil
      assert RepoConfig.parse("- just\n- a\n- list\n") == nil
    end

    test "empty agents list falls back (no agents key in result)" do
      assert RepoConfig.parse("agents: []\n")[:agents] == nil
    end
  end

  describe "fetch/2" do
    test "reads .bugseeker.yml from the repo at the given ref" do
      expect(GithubMock, :get_raw_contents, fn _repo, ".bugseeker.yml", "abc123" ->
        {:ok, "agents:\n  - typescript\nmin_inline_severity: MEDIUM\n"}
      end)

      config = RepoConfig.fetch(repo(), "abc123")

      assert config[:min_inline_severity] == "MEDIUM"
      assert Enum.all?(config[:agents], &String.starts_with?(&1, "typescript"))
    end

    test "falls back to .bugseeker.yaml" do
      expect(GithubMock, :get_raw_contents, fn _repo, ".bugseeker.yml", _ref ->
        {:error, :not_found}
      end)

      expect(GithubMock, :get_raw_contents, fn _repo, ".bugseeker.yaml", _ref ->
        {:ok, "agents:\n  - nestjs_security\n"}
      end)

      assert RepoConfig.fetch(repo(), "abc123")[:agents] == ["nestjs_security"]
    end

    test "returns nil when the repo has no config file" do
      expect(GithubMock, :get_raw_contents, 2, fn _repo, _path, _ref ->
        {:error, :not_found}
      end)

      assert RepoConfig.fetch(repo(), "abc123") == nil
    end

    test "returns nil on api errors" do
      expect(GithubMock, :get_raw_contents, 2, fn _repo, _path, _ref ->
        {:error, %{reason: :api_error}}
      end)

      assert RepoConfig.fetch(repo(), "abc123") == nil
    end
  end

  test "every loaded agent is expandable by its framework prefix" do
    # Guards the bundle-expansion contract: `agents: [react_js]` must cover
    # all react_js_* agents, etc.
    for name <- Cache.all_names(), String.contains?(name, "_") do
      prefix = name |> String.split("_") |> List.first()
      config = RepoConfig.parse("agents:\n  - #{prefix}\n")
      assert name in config[:agents]
    end
  end
end
