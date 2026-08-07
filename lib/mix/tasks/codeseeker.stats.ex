defmodule Mix.Tasks.Codeseeker.Stats do
  @shortdoc "Prints in-memory review statistics"
  @moduledoc """
  Prints the in-memory review counters collected by `Codeseeker.Stats`.

      mix codeseeker.stats

  Counters are process-local and lost on restart; for durable reporting,
  export the structured logs to a log aggregator instead.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    snapshot = Codeseeker.Stats.snapshot()

    IO.puts("=== Codeseeker stats ===")
    IO.puts("Total reviews: #{snapshot.total_reviews}")
    IO.puts("Outcomes: " <> inspect(snapshot.outcomes))
    IO.puts("DeepSeek calls: #{snapshot.deepseek.ok} ok / #{snapshot.deepseek.error} error")
    IO.puts("\nIssues by severity:")
    print_map(snapshot.by_severity)
    IO.puts("\nIssues by skill:")
    print_map(snapshot.by_skill)

    if snapshot.recent_duration_ms != [] do
      durations = snapshot.recent_duration_ms
      avg = div(Enum.sum(durations), length(durations))

      IO.puts(
        "\nRecent review durations (ms, last #{length(durations)}): avg #{avg}, latest #{List.first(durations)}"
      )
    end
  end

  defp print_map(map) do
    if map == %{} do
      IO.puts("  (none yet)")
    else
      Enum.each(Enum.sort_by(map, fn {_k, v} -> -v end), fn {key, count} ->
        IO.puts("  #{key}: #{count}")
      end)
    end
  end
end
