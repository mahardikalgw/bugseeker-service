defmodule Codeseeker.AgentsTest do
  use ExUnit.Case, async: true

  alias Codeseeker.Agents
  alias Codeseeker.Agents.{Agent, Cache}

  describe "Cache" do
    test "loads the framework-specific agents" do
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

      assert "nestjs_architecture" in names
      assert "nestjs_security" in names
      assert "nestjs_performance" in names
      assert "nestjs_code_quality" in names
      assert "nestjs_testing" in names
    end

    test "parses the severity bias out of the content" do
      security = Cache.get("react_js_security")
      assert security.severity_bias["xss"] == "CRITICAL"
      assert security.content =~ "## Rules"
      refute security.content =~ "## Severity"
    end

    test "every agent exposes its parsed severity bias" do
      assert Cache.get("react_js_security").severity_bias["dangerous innerhtml"] == "CRITICAL"
    end
  end

  describe "Agents.apply_bias/2" do
    alias Codeseeker.Reviews.Issue

    test "raises severity when the message matches a bias key" do
      agent = Cache.get("react_js_security")

      issue = %Issue{
        file_path: "a.tsx",
        line: 1,
        severity: "MEDIUM",
        category: "security",
        message: "XSS via dangerouslySetInnerHTML"
      }

      assert [%Issue{severity: "CRITICAL"}] = Agents.apply_bias([issue], agent)
    end

    test "keeps severity when nothing matches" do
      agent = Cache.get("react_js_security")

      issue = %Issue{
        file_path: "a.tsx",
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

    test "framework agents declare their file types" do
      assert ".tsx" in Cache.get("react_js_security").file_extensions
      assert ".ts" in Cache.get("nestjs_security").file_extensions
    end
  end
end
