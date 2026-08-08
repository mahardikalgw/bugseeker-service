defmodule Codeseeker.AgentsTest do
  use ExUnit.Case, async: true

  alias Codeseeker.Agents
  alias Codeseeker.Agents.{Agent, Cache}

  describe "Cache" do
    test "loads every agent markdown file" do
      names = Cache.all_names()

      assert "bug" in names
      assert "security" in names
      assert "performance" in names
      assert "code_quality" in names
      assert "architecture" in names
      assert "maintainability" in names
      assert "testing" in names
      assert "dependency" in names
      assert "api_contract" in names
    end

    test "parses the severity bias out of the content" do
      security = Cache.get("security")
      assert security.severity_bias["sql injection"] == "CRITICAL"
      assert security.content =~ "## Rules"
      assert security.content =~ "XSS"
      refute security.content =~ "## Severity"
    end

    test "every agent exposes its parsed severity bias" do
      assert Cache.get("security").severity_bias["sql injection"] == "CRITICAL"
    end
  end

  describe "Agents.apply_bias/2" do
    alias Codeseeker.Reviews.Issue

    test "raises severity when the message matches a bias key" do
      agent = Cache.get("security")

      issue = %Issue{
        file_path: "a.ts",
        line: 1,
        severity: "MEDIUM",
        category: "security",
        message: "SQL injection from user input"
      }

      assert [%Issue{severity: "CRITICAL"}] = Agents.apply_bias([issue], agent)
    end

    test "keeps severity when nothing matches" do
      agent = Cache.get("security")

      issue = %Issue{
        file_path: "a.ts",
        line: 1,
        severity: "MEDIUM",
        category: "style",
        message: "line too long"
      }

      assert [%Issue{severity: "MEDIUM"}] = Agents.apply_bias([issue], agent)
    end
  end

  describe "Agent.parse/1" do
    test "strips the severity section from content" do
      content = """
      # Agent: Test

      You are a reviewer.

      ## Rules
      - one

      ## Severity
      - xss: CRITICAL
      """

      {instructions, bias} = Agent.parse(content)
      assert instructions =~ "You are a reviewer."
      refute instructions =~ "CRITICAL"
      assert bias == %{"xss" => "CRITICAL"}
    end
  end
end
