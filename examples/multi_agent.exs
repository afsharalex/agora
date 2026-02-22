# Multi-Agent Orchestration Example
#
# Demonstrates RoundRobin orchestration with multiple agents
# using the Agora.round_robin/3 composition function.
#
# Run with: mix run examples/multi_agent.exs

alias Agora.Orchestrator.TerminationCondition

researcher =
  Agora.agent(:echo, "echo",
    name: "researcher",
    instructions: "You are a research assistant.",
    provider_opts: [
      echo_mode: :static,
      echo_response:
        "Research findings: The BEAM VM enables massive concurrency through lightweight processes."
    ]
  )

writer =
  Agora.agent(:echo, "echo",
    name: "writer",
    instructions: "You are a technical writer.",
    provider_opts: [
      echo_mode: :static,
      echo_response:
        "Article draft: Elixir's concurrency model, built on the BEAM VM, uses lightweight processes. FINAL ANSWER"
    ]
  )

IO.puts("=== Multi-Agent Orchestration (RoundRobin) ===\n")

{:ok, response} =
  Agora.round_robin(
    "Research and write about BEAM concurrency",
    [researcher: researcher, writer: writer],
    termination:
      TerminationCondition.any_of([
        TerminationCondition.max_turns(3),
        TerminationCondition.keyword_match(["FINAL ANSWER"])
      ])
  )

IO.puts("Final response: #{response.content}")
IO.puts("\n[Orchestration complete]")
