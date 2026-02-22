# Supervisor Orchestration Example
#
# Demonstrates delegation orchestration using Agora.supervisor/4.
# A manager agent delegates tasks to specialist workers via DELEGATE:name:message.
#
# Run with: mix run examples/supervisor.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

manager =
  Agora.agent(:openai, "gpt-4o",
    name: "manager",
    instructions: """
    You are a project manager who delegates tasks to specialist workers.
    You have two workers available: "analyst" and "writer".

    To delegate a task, your response MUST start with this exact format:
    DELEGATE:worker_name:message to send

    For example:
    DELEGATE:analyst:Analyze the performance characteristics of GenServer

    After receiving a worker's response, either delegate another task or provide
    your final summary. When you are done delegating, respond normally without
    the DELEGATE prefix.

    For the current task, delegate the analysis work to the analyst first,
    then synthesize the results.
    """
  )

analyst =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "analyst",
    instructions:
      "You are a performance analyst specializing in Erlang/Elixir systems. Provide detailed technical analysis when asked. Keep responses focused and concise."
  )

writer =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "writer",
    instructions:
      "You are a technical writer. Write clear, well-structured documentation based on the information provided."
  )

IO.puts("=== Supervisor Orchestration (Delegation) ===\n")

{:ok, response} =
  Agora.supervisor(
    "Document GenServer performance characteristics",
    {:manager, manager},
    analyst: analyst,
    writer: writer
  )

IO.puts("Final response: #{response.content}")
IO.puts("\n[Supervisor orchestration complete]")
