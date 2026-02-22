# Parallel Workflow Example
#
# Demonstrates fan-out/fan-in using the Workflow Patterns API.
# A source step feeds two branches that run concurrently, then a sink merges results.
#
# Run with: mix run examples/parallel_workflow.exs

alias Agora.Workflow.Patterns

IO.puts("=== Parallel Workflow (Fan-out/Fan-in) ===\n")

{:ok, workflow} =
  Patterns.parallel(
    [
      {:analyze,
       fn results ->
         {:ok, data} = results[:source]
         IO.puts("  [analyze] Analyzing #{length(data)} items...")

         {:ok,
          %{
            count: length(data),
            avg_length: Enum.sum(Enum.map(data, &String.length/1)) / length(data)
          }}
       end},
      {:summarize,
       fn results ->
         {:ok, data} = results[:source]
         IO.puts("  [summarize] Summarizing #{length(data)} items...")
         {:ok, "Items: #{Enum.join(data, ", ")}"}
       end}
    ],
    from:
      {:source,
       fn _results ->
         IO.puts("  [source] Fetching data...")
         {:ok, ["elixir", "erlang", "gleam"]}
       end},
    to:
      {:merge,
       fn results ->
         {:ok, analysis} = results[:analyze]
         {:ok, summary} = results[:summarize]
         IO.puts("  [merge] Combining results...")
         {:ok, %{analysis: analysis, summary: summary}}
       end}
  )

{:ok, results} = Agora.run_workflow(workflow)

{:ok, final} = results[:merge]
IO.puts("\nMerged result: #{inspect(final)}")
IO.puts("\n[Parallel workflow complete]")
