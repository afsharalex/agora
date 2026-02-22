# Workflow Example
#
# Demonstrates DAG-based workflow execution with parallel fan-out.
# Uses pure functions (no API key needed).
#
# Run with: mix run examples/workflow.exs

alias Agora.Workflow.Builder

IO.puts("=== Workflow Example (Parallel Fan-Out) ===\n")

# Build a workflow with parallel steps using after: for dependency declaration
workflow =
  Builder.new()
  |> Builder.step(:fetch_users, fn _results ->
    IO.puts("[fetch_users] Fetching user data...")
    {:ok, ["Alice", "Bob", "Charlie"]}
  end)
  |> Builder.step(
    :count_users,
    fn results ->
      {:ok, users} = results[:fetch_users]
      count = length(users)
      IO.puts("[count_users] Found #{count} users")
      {:ok, count}
    end, after: :fetch_users)
  |> Builder.step(
    :format_names,
    fn results ->
      {:ok, users} = results[:fetch_users]
      formatted = Enum.map_join(users, ", ", &String.upcase/1)
      IO.puts("[format_names] Formatted: #{formatted}")
      {:ok, formatted}
    end, after: :fetch_users)
  |> Builder.step(
    :summary,
    fn results ->
      {:ok, count} = results[:count_users]
      {:ok, names} = results[:format_names]
      summary = "#{count} users: #{names}"
      IO.puts("[summary] #{summary}")
      {:ok, summary}
    end, after: [:count_users, :format_names])
  |> Builder.build!()

IO.puts("Workflow built. Executing...\n")

{:ok, results} = Agora.run_workflow(workflow)

IO.puts("\n=== Results ===")

for {step, result} <- Enum.sort(results) do
  IO.puts("  #{step}: #{inspect(result)}")
end
