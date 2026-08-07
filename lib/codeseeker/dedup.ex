defmodule Codeseeker.Dedup do
  @moduledoc """
  In-memory guard against duplicate review runs, replacing the DB unique
  constraint of a database-backed design.

  Keys are `{owner, name, pr_number, head_sha}`. An entry is `:processing`
  while a coordinator runs, then `:done` for `dedup_ttl_seconds` so webhook
  redeliveries do not re-review the same SHA. Entries are evicted by a
  periodic cleanup.
  """

  use GenServer

  @table :codeseeker_dedup
  @cleanup_interval_ms 300_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Marks `key` as processing.

  Returns `:ok` when the key was free (or its `:done` entry expired), and
  `:duplicate` when a coordinator is already processing it or it was
  reviewed recently.
  """
  @spec begin_processing(term()) :: :ok | :duplicate
  def begin_processing(key), do: GenServer.call(__MODULE__, {:begin, key})

  @doc "Marks `key` as successfully handled (or failed after retries)."
  @spec mark_done(term()) :: :ok
  def mark_done(key), do: GenServer.call(__MODULE__, {:done, key})

  @doc "Returns whether `key` is currently held (processing or done within TTL)."
  @spec held?(term()) :: boolean()
  def held?(key), do: GenServer.call(__MODULE__, {:held?, key})

  @doc "Returns whether `key` was marked done (used by tests to wait for completion)."
  @spec done?(term()) :: boolean()
  def done?(key), do: GenServer.call(__MODULE__, {:done?, key})

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:begin, key}, _from, state) do
    ttl = Application.get_env(:codeseeker, :dedup_ttl_seconds, 3600)
    now = System.monotonic_time(:second)

    case :ets.lookup(state.table, key) do
      [] ->
        :ets.insert(state.table, {key, :processing, now})
        {:reply, :ok, state}

      [{^key, :processing, _ts}] ->
        {:reply, :duplicate, state}

      [{^key, :done, ts}] ->
        if now - ts < ttl do
          {:reply, :duplicate, state}
        else
          :ets.insert(state.table, {key, :processing, now})
          {:reply, :ok, state}
        end
    end
  end

  def handle_call({:done, key}, _from, state) do
    :ets.insert(state.table, {key, :done, System.monotonic_time(:second)})
    {:reply, :ok, state}
  end

  def handle_call({:held?, key}, _from, state) do
    {:reply, :ets.member(state.table, key), state}
  end

  def handle_call({:done?, key}, _from, state) do
    {:reply, match?([{^key, :done, _}], :ets.lookup(state.table, key)), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    ttl = Application.get_env(:codeseeker, :dedup_ttl_seconds, 3600)
    now = System.monotonic_time(:second)
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:<, :"$1", now - ttl}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
