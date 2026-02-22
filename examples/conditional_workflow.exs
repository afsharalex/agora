# Conditional Workflow Example
#
# Demonstrates input-dependent routing using the Workflow Patterns API.
# A router step classifies input, then condition functions determine which branch runs.
#
# Run with: mix run examples/conditional_workflow.exs

alias Agora.Workflow.Patterns

IO.puts("=== Conditional Workflow (Input Router) ===\n")

router =
  {:classify,
   fn _results ->
     input = "urgent: server down"
     IO.puts("  [classify] Classifying: #{inspect(input)}")

     cond do
       String.starts_with?(input, "urgent") -> {:ok, :urgent}
       String.starts_with?(input, "question") -> {:ok, :question}
       true -> {:ok, :general}
     end
   end}

branches = [
  {fn r -> r[:classify] == {:ok, :urgent} end,
   {:handle_urgent,
    fn _r ->
      IO.puts("  [handle_urgent] Escalating to on-call team!")
      {:ok, "Incident created, on-call notified"}
    end}},
  {fn r -> r[:classify] == {:ok, :question} end,
   {:handle_question,
    fn _r ->
      IO.puts("  [handle_question] Searching knowledge base...")
      {:ok, "Found 3 matching articles"}
    end}}
]

{:ok, workflow} =
  Patterns.conditional(router, branches,
    merge:
      {:report,
       fn results ->
         handled =
           cond do
             results[:handle_urgent] ->
               {:ok, msg} = results[:handle_urgent]
               msg

             results[:handle_question] ->
               {:ok, msg} = results[:handle_question]
               msg

             true ->
               "No branch matched"
           end

         IO.puts("  [report] Building report...")
         {:ok, "Report: #{handled}"}
       end}
  )

{:ok, results} = Agora.run_workflow(workflow)

{:ok, report} = results[:report]
IO.puts("\nFinal: #{report}")
IO.puts("\n[Conditional workflow complete]")
