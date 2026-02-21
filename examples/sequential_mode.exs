# Sequential Mode Example
#
# Demonstrates a linear pipeline using run_mode(:sequential, ...).
# Steps execute in order, each receiving the accumulated results map.
#
# Run with: mix run examples/sequential_mode.exs

IO.puts("=== Sequential Mode (ETL Pipeline) ===\n")

{:ok, results} = Agora.run_mode(:sequential, [
  {:fetch, fn _results ->
    IO.puts("  [fetch] Loading raw data...")
    {:ok, ["alice", "bob", "carol"]}
  end},

  {:transform, fn results ->
    {:ok, names} = results[:fetch]
    IO.puts("  [transform] Normalizing #{length(names)} records...")
    {:ok, Enum.map(names, &String.capitalize/1)}
  end},

  {:load, fn results ->
    {:ok, names} = results[:transform]
    IO.puts("  [load] Saving #{length(names)} records...")
    {:ok, %{saved: length(names), records: names}}
  end}
])

{:ok, final} = results[:load]
IO.puts("\nPipeline result: #{inspect(final)}")
IO.puts("\n[Sequential mode complete]")
