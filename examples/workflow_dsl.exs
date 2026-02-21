# Workflow DSL Example
#
# Demonstrates the block macro DSL for defining workflow DAGs.
# Uses pure functions (no API key needed).
#
# Run with: mix run examples/workflow_dsl.exs

import Agora.Workflow.DSL

IO.puts("=== Workflow DSL Example ===\n")

# Build a workflow using the block DSL with visual ~> wiring
w = workflow do
  step :fetch_users do
    IO.puts("[fetch_users] Fetching user data...")
    {:ok, ["Alice", "Bob", "Charlie"]}
  end

  step :count_users, after: :fetch_users do
    {:ok, users} = results[:fetch_users]
    count = length(users)
    IO.puts("[count_users] Found #{count} users")
    {:ok, count}
  end

  step :format_names, after: :fetch_users do
    {:ok, users} = results[:fetch_users]
    formatted = Enum.map_join(users, ", ", &String.upcase/1)
    IO.puts("[format_names] Formatted: #{formatted}")
    {:ok, formatted}
  end

  step :summary, run: fn r ->
    {:ok, count} = r[:count_users]
    {:ok, names} = r[:format_names]
    summary = "#{count} users: #{names}"
    IO.puts("[summary] #{summary}")
    {:ok, summary}
  end

  # Visual DAG wiring — fan-in from count and format to summary
  [:count_users, :format_names] ~> :summary
end

IO.puts("Workflow built. Executing...\n")

{:ok, results} = Agora.run_workflow(w)

IO.puts("\n=== Results ===")

for {step, result} <- Enum.sort(results) do
  IO.puts("  #{step}: #{inspect(result)}")
end

IO.puts("\n=== Conditional Workflow ===\n")

# Demonstrate conditional edges
w2 = workflow do
  step :check do
    value = Enum.random([:go, :stop])
    IO.puts("[check] Decision: #{value}")
    {:ok, value}
  end

  step :proceed, run: fn _ ->
    IO.puts("[proceed] Proceeding!")
    {:ok, "proceeded"}
  end

  step :halt, run: fn _ ->
    IO.puts("[halt] Halting!")
    {:ok, "halted"}
  end

  edge :check, :proceed, condition: fn r -> r[:check] == {:ok, :go} end
  edge :check, :halt, condition: fn r -> r[:check] == {:ok, :stop} end
end

{:ok, results2} = Agora.run_workflow(w2)

IO.puts("\n=== Conditional Results ===")

for {step, result} <- Enum.sort(results2) do
  IO.puts("  #{step}: #{inspect(result)}")
end
