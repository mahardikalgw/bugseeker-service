defmodule Bugseeker.Stats do
  @moduledoc """
  In-memory runtime counters (ETS), readable via `mix bugseeker.stats`.

  Counters are lost on restart; for durable reporting, export structured
  logs to a log aggregator instead.
  """

  use GenServer

  alias Bugseeker.Reviews.Issue

  @table :bugseeker_stats

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Records a review outcome.

  `outcome` is `:ok | :failed | :skipped`; `issues` is the list of issues
  (or `[]`) for severity/skill histograms; `duration_ms` is optional.
  """
  @spec record(:ok | :failed | :skipped, [Issue.t()], non_neg_integer() | nil) :: :ok
  def record(outcome, issues, duration_ms \\ nil) do
    bump({:total, :all})
    bump({:outcome, outcome})

    Enum.each(issues, fn issue ->
      bump({:severity, issue.severity})
      bump({:agent, issue.agent || "unknown"})
    end)

    if duration_ms do
      update_durations(duration_ms)
    end

    :ok
  end

  @doc "Records a DeepSeek call outcome."
  @spec record_deepseek(:ok | :error) :: :ok
  def record_deepseek(outcome) do
    bump({:deepseek, outcome})
    :ok
  end

  defp bump(key), do: :ets.update_counter(@table, key, 1, {key, 0})

  @doc "Returns a snapshot of all counters."
  @spec snapshot() :: map()
  def snapshot do
    values = :ets.tab2list(@table)
    durations = for {:"$durations", list} <- values, do: list
    values = Keyword.delete(values, :"$durations")

    %{
      total_reviews: counter(values, {:total, :all}),
      outcomes:
        for(o <- [:ok, :failed, :skipped], into: %{}, do: {o, counter(values, {:outcome, o})}),
      by_severity: histogram(values, :severity),
      by_agent: histogram(values, :agent),
      deepseek: %{
        ok: counter(values, {:deepseek, :ok}),
        error: counter(values, {:deepseek, :error})
      },
      recent_duration_ms: durations
    }
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    {:ok, %{}}
  end

  defp update_durations(duration_ms) do
    current =
      case :ets.lookup(@table, :"$durations") do
        [{_, list}] -> list
        [] -> []
      end

    updated = [duration_ms | current] |> Enum.take(100)
    :ets.insert(@table, {:durations, updated})
  end

  defp counter(values, key) do
    Enum.find_value(values, 0, fn
      {^key, count} -> count
      _ -> nil
    end)
  end

  defp histogram(values, kind) do
    values
    |> Enum.filter(fn {key, _} -> match?({^kind, _}, key) end)
    |> Map.new(fn {{^kind, name}, count} -> {name, count} end)
  end
end
