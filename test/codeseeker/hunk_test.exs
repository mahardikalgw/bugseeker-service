defmodule Codeseeker.HunkTest do
  use ExUnit.Case, async: true

  alias Codeseeker.Hunk

  describe "new_line_ranges/1" do
    test "parses a simple hunk header" do
      patch = """
      @@ -1,5 +1,7 @@
       line1
      -line2
      +new2
      +new3
       line5
      """

      assert Hunk.new_line_ranges(patch) == [{1, 7}]
    end

    test "parses multiple hunks in file order" do
      patch = """
      @@ -10,3 +10,4 @@
      @@ -40,0 +45,3 @@
      """

      assert Hunk.new_line_ranges(patch) == [{10, 13}, {45, 47}]
    end

    test "skips hunks with a zero new-side count (pure deletion)" do
      patch = """
      @@ -5,3 +0,0 @@
      -gone
      -gone2
      """

      assert Hunk.new_line_ranges(patch) == []
    end

    test "handles a count-less header (single line)" do
      assert Hunk.new_line_ranges("@@ -1 +1 @@") == [{1, 1}]
    end

    test "handles nil and non-diff input" do
      assert Hunk.new_line_ranges(nil) == []
      assert Hunk.new_line_ranges("just a line") == []
    end
  end

  describe "line_in_ranges?/2" do
    test "true when inside a range" do
      assert Hunk.line_in_ranges?(3, [{1, 7}])
      assert Hunk.line_in_ranges?(46, [{10, 13}, {45, 47}])
    end

    test "false when outside all ranges" do
      refute Hunk.line_in_ranges?(8, [{1, 7}])
      refute Hunk.line_in_ranges?(14, [{10, 13}, {45, 47}])
    end
  end
end
