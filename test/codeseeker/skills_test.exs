defmodule Codeseeker.SkillsTest do
  use ExUnit.Case, async: true

  alias Codeseeker.Skills.{Cache, Registry, Skill}

  describe "Cache" do
    test "loads every markdown skill from the skills dir" do
      names = Cache.all_names()
      assert "generic" in names
      assert "typescript" in names
      assert "go" in names
      assert "php" in names
      assert "elixir" in names
    end

    test "parses the severity bias out of the content" do
      ts = Cache.get("typescript")

      assert %{"xss" => "CRITICAL", "sql injection" => "CRITICAL", "excessive any" => "LOW"} =
               ts.severity_bias

      assert ts.content =~ "## Rules"
      assert ts.content =~ "innerHTML"
      refute ts.content =~ "## Severity"
    end

    test "skills without a severity section get an empty bias" do
      assert Cache.get("generic").severity_bias == %{}
    end
  end

  describe "Registry.resolve/1" do
    test "maps extensions to their skill" do
      assert Registry.resolve("src/api.ts").name == "typescript"
      assert Registry.resolve("src/App.tsx").name == "typescript"
      assert Registry.resolve("cmd/main.go").name == "go"
      assert Registry.resolve("index.php").name == "php"
      assert Registry.resolve("lib/foo.ex").name == "elixir"
      assert Registry.resolve("lib/foo.exs").name == "elixir"
    end

    test "falls back to generic for unknown extensions" do
      assert Registry.resolve("README.txt").name == "generic"
      assert Registry.resolve("no_extension").name == "generic"
    end
  end

  describe "Registry.prompt_for/3" do
    test "composes base prompt, skill content, guidelines and diff" do
      skill = Registry.resolve("a.go")
      file = %{path: "a.go", patch: "@@ -1,3 +1,3 @@\n-foo\n+bar"}

      prompt = Registry.prompt_for(skill, file, "Always use context.")
      assert prompt =~ "You are a senior code reviewer"
      assert prompt =~ "## SKILL: go"
      assert prompt =~ "goroutine leaks"
      assert prompt =~ "TEAM GUIDELINES"
      assert prompt =~ "Always use context."
      assert prompt =~ "## FILE: a.go"
      assert prompt =~ "+bar"
    end

    test "omits guidelines section when nil" do
      skill = Registry.resolve("a.go")
      prompt = Registry.prompt_for(skill, %{path: "a.go", patch: ""}, nil)
      refute prompt =~ "TEAM GUIDELINES"
    end
  end

  describe "Registry.apply_bias/2" do
    alias Codeseeker.Review.Issue

    test "raises severity when the message matches a bias key" do
      skill = Cache.get("typescript")

      issue = %Issue{
        file_path: "a.ts",
        line: 1,
        severity: "MEDIUM",
        category: "security",
        message: "XSS via innerHTML with user input"
      }

      assert [%Issue{severity: "CRITICAL"}] = Registry.apply_bias([issue], skill)
    end

    test "keeps severity when nothing matches" do
      skill = Cache.get("typescript")

      issue = %Issue{
        file_path: "a.ts",
        line: 1,
        severity: "MEDIUM",
        category: "style",
        message: "line too long"
      }

      assert [%Issue{severity: "MEDIUM"}] = Registry.apply_bias([issue], skill)
    end
  end

  describe "Skill.parse/1" do
    test "strips the severity section from content" do
      content = """
      # Skill: Test

      You are a reviewer.

      ## Rules
      - one

      ## Severity
      - xss: CRITICAL
      """

      {instructions, bias} = Skill.parse(content)
      assert instructions =~ "You are a reviewer."
      refute instructions =~ "CRITICAL"
      assert bias == %{"xss" => "CRITICAL"}
    end
  end
end
