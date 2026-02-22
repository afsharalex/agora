# Sequential Workflow Example
#
# Demonstrates a linear pipeline using the Workflow Patterns API.
# Steps execute in order, each receiving the accumulated results map.
#
# Run with: mix run examples/sequential_mode.exs

alias Agora.Workflow.Patterns

IO.puts("=== Sequential Workflow (ETL Pipeline) ===\n")

{:ok, workflow} = Patterns.sequential([
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

{:ok, results} = Agora.run_workflow(workflow)

{:ok, final} = results[:load]
IO.puts("\nPipeline result: #{inspect(final)}")
IO.puts("\n[Sequential workflow complete]")
