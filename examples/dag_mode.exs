# DAG Mode Example
#
# Demonstrates complex DAG topology via Builder API with run_mode(:dag, ...).
# For simpler topologies, use :sequential, :parallel, or :conditional modes.
# For the Builder API without run_mode, see workflow.exs.
#
# Run with: mix run examples/dag_mode.exs

alias Agora.Workflow.Builder

IO.puts("=== DAG Mode (Complex Topology) ===\n")

# Build a workflow with mixed parallel and sequential dependencies:
#   fetch_users ──┬── count_users ────┐
#                 └── format_names ───┼── summary
workflow =
  Builder.new()
  |> Builder.step(:fetch_users, fn _results ->
    IO.puts("  [fetch_users] Loading user data...")
    {:ok, [%{name: "Alice", age: 30}, %{name: "Bob", age: 25}, %{name: "Carol", age: 35}]}
  end)
  |> Builder.step(:count_users, fn results ->
    {:ok, users} = results[:fetch_users]
    IO.puts("  [count_users] Counting...")
    {:ok, length(users)}
  end, after: :fetch_users)
  |> Builder.step(:format_names, fn results ->
    {:ok, users} = results[:fetch_users]
    IO.puts("  [format_names] Formatting...")
    {:ok, Enum.map_join(users, ", ", & &1.name)}
  end, after: :fetch_users)
  |> Builder.step(:summary, fn results ->
    {:ok, count} = results[:count_users]
    {:ok, names} = results[:format_names]
    IO.puts("  [summary] Building summary...")
    {:ok, "#{count} users: #{names}"}
  end, after: [:count_users, :format_names])
  |> Builder.build!()

{:ok, results} = Agora.run_mode(:dag, workflow)

{:ok, summary} = results[:summary]
IO.puts("\nResult: #{summary}")
IO.puts("\n[DAG mode complete]")
