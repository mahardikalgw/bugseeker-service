defmodule Codeseeker.DedupTest do
  use ExUnit.Case, async: false

  alias Codeseeker.Dedup

  setup do
    if :ets.whereis(:codeseeker_dedup), do: :ets.delete_all_objects(:codeseeker_dedup)
    :ok
  end

  describe "begin_processing/1" do
    test "allows a new key and marks it processing" do
      assert Dedup.begin_processing({:o, :r, 1, "sha"}) == :ok
      assert Dedup.held?({:o, :r, 1, "sha"})
    end

    test "rejects a second begin while processing" do
      key = {:o, :r, 1, "sha"}
      assert Dedup.begin_processing(key) == :ok
      assert Dedup.begin_processing(key) == :duplicate
    end

    test "rejects a completed key within the TTL" do
      key = {:o, :r, 1, "sha"}
      assert Dedup.begin_processing(key) == :ok
      Dedup.mark_done(key)
      assert Dedup.begin_processing(key) == :duplicate
    end
  end
end
