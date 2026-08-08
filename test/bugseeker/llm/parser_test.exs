defmodule Bugseeker.Llm.ParserTest do
  use ExUnit.Case, async: true

  alias Bugseeker.Agents.Cache
  alias Bugseeker.Llm.Parser
  alias Bugseeker.Reviews.Issue

  defp agent, do: Cache.get("typescript_security")

  describe "parse/3" do
    test "parses valid issues" do
      content =
        ~s({"issues":[{"file_path":"src/api.ts","line":84,"severity":"HIGH","category":"security","message":"Query built by concatenation","recommendation":"Use parameters"}]})

      assert {:ok, [issue]} = Parser.parse(content, nil, agent())

      assert %Issue{file_path: "src/api.ts", line: 84, severity: "HIGH", category: "security"} =
               issue

      assert issue.recommendation == "Use parameters"
      assert issue.agent == "typescript_security"
    end

    test "uses the default file_path when an item has none" do
      content = ~s({"issues":[{"line":5,"severity":"LOW","category":"style","message":"m"}]})
      assert {:ok, [%Issue{file_path: "a.ts"}]} = Parser.parse(content, "a.ts", agent())
    end

    test "drops items with no file_path and no default" do
      content = ~s({"issues":[{"line":5,"severity":"LOW","category":"style","message":"m"}]})
      assert {:ok, []} = Parser.parse(content, nil, agent())
    end

    test "handles empty issues" do
      assert {:ok, []} = Parser.parse(~s({"issues":[]}), "a.ts", agent())
    end

    test "normalizes severity/category case" do
      content =
        ~s({"issues":[{"file_path":"a.ts","line":1,"severity":"high","category":"Security","message":"m"}]})

      assert {:ok, [%Issue{severity: "HIGH", category: "security"}]} =
               Parser.parse(content, nil, agent())
    end

    test "drops items with invalid enums" do
      content =
        ~s({"issues":[{"file_path":"a.ts","line":1,"severity":"EXTREME","category":"security","message":"bad"},{"file_path":"a.ts","line":2,"severity":"LOW","category":"security","message":"ok"}]})

      assert {:ok, [issue]} = Parser.parse(content, nil, agent())
      assert issue.line == 2
    end

    test "drops items with nil line instead of crashing" do
      content =
        ~s({"issues":[{"file_path":"a.ts","line":null,"severity":"LOW","category":"style","message":"m"}]})

      assert {:ok, [%Issue{line: nil}]} = Parser.parse(content, nil, agent())
    end

    test "applies severity bias from the agent" do
      content =
        ~s({"issues":[{"file_path":"a.ts","line":1,"severity":"MEDIUM","category":"security","message":"potential eval-injection from user input"}]})

      assert {:ok, [%{severity: "CRITICAL"}]} = Parser.parse(content, nil, agent())
    end

    test "returns unparseable for invalid JSON" do
      assert {:error, :unparseable} = Parser.parse("not json at all", "a.ts", agent())
    end

    test "returns unparseable for valid JSON without issues key" do
      assert {:error, :unparseable} = Parser.parse(~s({"foo": 1}), "a.ts", agent())
    end

    test "returns unparseable for nil content" do
      assert {:error, :unparseable} = Parser.parse(nil, "a.ts", agent())
    end
  end
end
