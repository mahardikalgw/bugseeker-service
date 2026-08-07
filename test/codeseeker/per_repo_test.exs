defmodule Codeseeker.PerRepoTest do
  use ExUnit.Case, async: false

  alias Codeseeker.PerRepo

  # Each test uses its own repo key so the shared global state never leaks
  # between tests (ExUnit runs tests in random order).
  defp repo(suffix),
    do: %{owner: "per-repo-#{suffix}", name: "repo", installation_id: 1}

  describe "defaults" do
    test "repo without overrides is enabled with :all skills and global threshold" do
      r = repo(:defaults)
      assert PerRepo.enabled?(r)
      assert PerRepo.skills(r) == :all
      assert PerRepo.min_inline_severity(r) == "HIGH"
    end
  end

  describe "overrides" do
    test "enabled/disabled toggle" do
      r = repo(:toggle)
      PerRepo.set_enabled(r, false)
      refute PerRepo.enabled?(r)
      PerRepo.set_enabled(r, true)
      assert PerRepo.enabled?(r)
    end

    test "skill enable/disable resolves to explicit lists" do
      r = repo(:skills)
      PerRepo.enable_skill(r, "go")
      assert "go" in PerRepo.active_skill_names(r)
      assert PerRepo.skills(r) |> is_list()

      PerRepo.disable_skill(r, "go")
      refute "go" in PerRepo.active_skill_names(r)
    end

    test "min inline severity override" do
      r = repo(:severity)
      PerRepo.set_min_inline_severity(r, "critical")
      assert PerRepo.min_inline_severity(r) == "CRITICAL"
    end

    test "overrides are visible via overrides/1" do
      r = repo(:visible)
      PerRepo.set_enabled(r, false)
      assert PerRepo.overrides(r)[:enabled] == false
    end
  end
end
