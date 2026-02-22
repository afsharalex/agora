# Plan Orchestration Example
#
# Demonstrates autonomous plan-execute-review orchestration using Agora.plan/4.
# A planner agent creates a structured plan, assigns steps to specialist workers,
# and reviews results before declaring completion.
#
# The framework injects format instructions for PLAN/STEP/END_PLAN and
# REVIEW:COMPLETE/CONTINUE syntax — the planner's instructions complement them.
#
# Run with: mix run examples/plan.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

planner =
  Agora.agent(:openai, "gpt-4o",
    name: "planner",
    instructions:
      "You are a project planner. Break tasks into steps and assign them to the available workers. Follow the planning and review format instructions exactly."
  )

researcher =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "researcher",
    instructions:
      "You are a technical researcher. Provide detailed, accurate research findings on the topic you're given. Focus on key concepts and technical details."
  )

writer =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "writer",
    instructions:
      "You are a technical writer. Write clear, engaging content based on the research or information provided. Do not invent facts — use only the material given."
  )

IO.puts("=== Plan Orchestration ===\n")

{:ok, response} =
  Agora.plan(
    "Write an article about BEAM concurrency",
    {:planner, planner},
    researcher: researcher,
    writer: writer
  )

IO.puts("Final result: #{String.slice(response.content, 0, 200)}...")
IO.puts("\n[Plan orchestration complete]")
