defmodule Codeseeker.Llm.ParserTest do
  use ExUnit.Case, async: true

  alias Codeseeker.Llm.Parser
  alias Codeseeker.Reviews.Issue
  alias Codeseeker.Skills.Cache

  defp skill, do: Cache.get("typescript")

  describe "parse/3" do
    test "parses valid issues" do
      content =
        ~s({"issues":[{"line":84,"severity":"HIGH","category":"security","message":"Query built by concatenation","recommendation":"Use parameters"}]})

      assert {:ok, [issue]} = Parser.parse(content, "src/api.ts", skill())

      assert %Issue{file_path: "src/api.ts", line: 84, severity: "HIGH", category: "security"} =
               issue

      assert issue.recommendation == "Use parameters"
      assert issue.skill == "typescript"
    end

    test "handles empty issues" do
      assert {:ok, []} = Parser.parse(~s({"issues":[]}), "a.ts", skill())
    end

    test "normalizes severity/category case" do
      content = ~s({"issues":[{"line":1,"severity":"high","category":"Security","message":"m"}]})

      assert {:ok, [%Issue{severity: "HIGH", category: "security"}]} =
               Parser.parse(content, "a.ts", skill())
    end

    test "drops items with invalid enums" do
      content =
        ~s({"issues":[{"line":1,"severity":"EXTREME","category":"security","message":"bad"},{"line":2,"severity":"LOW","category":"security","message":"ok"}]})

      assert {:ok, [issue]} = Parser.parse(content, "a.ts", skill())
      assert issue.line == 2
    end

    test "drops items with nil line instead of crashing" do
      content = ~s({"issues":[{"line":null,"severity":"LOW","category":"style","message":"m"}]})
      assert {:ok, [%Issue{line: nil}]} = Parser.parse(content, "a.ts", skill())
    end

    test "applies severity bias from the skill" do
      content =
        ~s({"issues":[{"line":1,"severity":"MEDIUM","category":"security","message":"XSS via innerHTML with user input"}]})

      assert {:ok, [%Issue{severity: "CRITICAL"}]} = Parser.parse(content, "a.ts", skill())
    end

    test "returns unparseable for invalid JSON" do
      assert {:error, :unparseable} = Parser.parse("not json at all", "a.ts", skill())
    end

    test "returns unparseable for valid JSON without issues key" do
      assert {:error, :unparseable} = Parser.parse(~s({"foo": 1}), "a.ts", skill())
    end

    test "returns unparseable for nil content" do
      assert {:error, :unparseable} = Parser.parse(nil, "a.ts", skill())
    end
  end
end
