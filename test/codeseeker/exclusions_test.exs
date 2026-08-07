defmodule Codeseeker.ExclusionsTest do
  use ExUnit.Case, async: true

  alias Codeseeker.Exclusions

  defp file(path, opts \\ %{}) do
    opts = Map.new(opts)

    %{
      path: path,
      patch: Map.get(opts, :patch, "@@ -1,3 +1,3 @@\n-a\n+b"),
      additions: Map.get(opts, :additions, 1)
    }
  end

  describe "filter/1" do
    test "keeps normal source files" do
      {kept, skipped} = Exclusions.filter([file("src/app.ts"), file("lib/helper.go")])
      assert Enum.map(kept, & &1.path) == ["src/app.ts", "lib/helper.go"]
      assert skipped == []
    end

    test "skips lockfiles and generated assets" do
      files = [
        file("package-lock.json"),
        file("yarn.lock"),
        file("go.sum"),
        file("mix.lock"),
        file("dist/bundle.min.js"),
        file("vendor/lib.go"),
        file("logo.png"),
        file("src/app.ts")
      ]

      {kept, skipped} = Exclusions.filter(files)
      assert Enum.map(kept, & &1.path) == ["src/app.ts"]
      assert length(skipped) == 7
      assert Enum.all?(skipped, &(&1.reason == "excluded pattern"))
    end

    test "skips binary patches" do
      {kept, skipped} = Exclusions.filter([file("data.bin", patch: "Binary files differ")])
      assert kept == []
      assert [%{reason: "binary file"}] = skipped
    end

    test "skips oversized patches and too many added lines" do
      big = String.duplicate("x", 301_000)

      {kept, skipped} =
        Exclusions.filter([file("big.ts", patch: big), file("many.ts", additions: 2000)])

      assert kept == []

      assert Enum.map(skipped, & &1.reason) == [
               "diff too large — manual review recommended",
               "diff too large — manual review recommended"
             ]
    end

    test "skips files with no patch (pure renames)" do
      {_kept, skipped} = Exclusions.filter([file("renamed.ts", patch: nil)])
      assert [%{reason: "no patch"}] = skipped
    end

    test "enforces the max files per PR" do
      files = Enum.map(1..35, &file("file#{&1}.ts"))
      {kept, skipped} = Exclusions.filter(files)
      assert length(kept) == 30
      assert Enum.any?(skipped, &(&1.reason == "30-file limit per PR"))
      assert Enum.any?(skipped, &(&1.path == "(5 more files)"))
    end

    test "order of skipping follows the file order" do
      {_kept, skipped} = Exclusions.filter([file("a.lock"), file("b.ts")])
      assert Enum.map(skipped, & &1.path) == ["a.lock"]
    end
  end
end
