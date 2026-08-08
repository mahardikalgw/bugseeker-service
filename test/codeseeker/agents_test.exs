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
    test "strips the severity and file types sections from content" do
      content = """
      # Agent: Test

      You are a reviewer.

      ## Rules
      - one

      ## File types
      - .tsx
      - .ts

      ## Severity
      - xss: CRITICAL
      """

      parsed = Agent.parse(content)
      assert parsed.content =~ "You are a reviewer."
      refute parsed.content =~ "## Severity"
      refute parsed.content =~ "## File types"
      assert parsed.file_extensions == [".tsx", ".ts"]
      assert parsed.severity_bias == %{"xss" => "CRITICAL"}
    end

    test "agents without file types get an empty list" do
      assert Cache.get("security").file_extensions == []
    end
  end

  describe "hierarchical agents" do
    test "framework-specific agents are loaded from sub-folders" do
      names = Cache.all_names()

      assert "react_js_architecture" in names
      assert "react_js_security" in names
      assert "react_js_performance" in names
      assert "react_js_code_quality" in names
      assert "react_js_testing" in names

      assert "typescript_architecture" in names
      assert "typescript_security" in names
      assert "typescript_performance" in names
      assert "typescript_code_quality" in names
      assert "typescript_testing" in names
    end

    test "framework-specific agents declare their file types" do
      agent = Cache.get("react_js_security")
      assert ".tsx" in agent.file_extensions
      assert ".ts" in agent.file_extensions

      ts = Cache.get("typescript_security")
      assert ".ts" in ts.file_extensions
      assert ".tsx" in ts.file_extensions
      assert ".js" in ts.file_extensions
    end
  end
end
