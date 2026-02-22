# DAG Workflow Example
#
# Demonstrates complex DAG topology via the Builder API.
# For simpler topologies, use Patterns.sequential/2 or Patterns.parallel/2.
#
# Run with: mix run examples/dag_mode.exs

alias Agora.Workflow.Builder

IO.puts("=== DAG Workflow (Complex Topology) ===\n")

# Build a workflow with mixed parallel and sequential dependencies:
#   fetch_users --+-- count_users ---+
#                 +-- format_names --+-- summary
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

{:ok, results} = Agora.run_workflow(workflow)

{:ok, summary} = results[:summary]
IO.puts("\nResult: #{summary}")
IO.puts("\n[DAG workflow complete]")
