# Workflow Module Example
#
# Demonstrates the module-level DSL for defining reusable workflow modules.
# Uses pure functions (no API key needed).
#
# Run with: mix run examples/workflow_module.exs

IO.puts("=== Workflow Module Example ===\n")

# Define a reusable workflow module
defmodule MyApp.Workflows.DataPipeline do
  use Agora.Workflow.Definition, timeout: 30_000

  step :fetch do
    IO.puts("[fetch] Fetching user data...")
    {:ok, ["Alice", "Bob", "Charlie"]}
  end

  step :count, after: :fetch do
    {:ok, users} = results[:fetch]
    count = length(users)
    IO.puts("[count] Found #{count} users")
    {:ok, count}
  end

  step :format, after: :fetch do
    {:ok, users} = results[:fetch]
    formatted = Enum.map_join(users, ", ", &String.upcase/1)
    IO.puts("[format] Formatted: #{formatted}")
    {:ok, formatted}
  end

  step :summary, run: fn r ->
    {:ok, count} = r[:count]
    {:ok, names} = r[:format]
    summary = "#{count} users: #{names}"
    IO.puts("[summary] #{summary}")
    {:ok, summary}
  end

  # Wire the DAG
  edge :count, :summary
  edge :format, :summary
end

# Introspection
IO.puts("Steps: #{inspect(MyApp.Workflows.DataPipeline.__workflow_steps__())}")
IO.puts("Executing...\n")

# Execute using the module atom
{:ok, results} = Agora.run_workflow(MyApp.Workflows.DataPipeline)

IO.puts("\n=== Results ===")

for {step, result} <- Enum.sort(results) do
  IO.puts("  #{step}: #{inspect(result)}")
end

IO.puts("\n=== Step Testing Example ===\n")

# Individual steps can be tested in isolation
mock_results = %{fetch: {:ok, ["Test"]}}
{:ok, count} = MyApp.Workflows.DataPipeline.__agora_step_count__(mock_results)
IO.puts("Step :count with mock data: #{inspect(count)}")

{:ok, formatted} = MyApp.Workflows.DataPipeline.__agora_step_format__(mock_results)
IO.puts("Step :format with mock data: #{inspect(formatted)}")
