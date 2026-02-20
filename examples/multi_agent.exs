# Multi-Agent Orchestration Example
#
# Demonstrates RoundRobin orchestration with multiple agents
# using explicit termination conditions.
#
# Run with: mix run examples/multi_agent.exs

alias Agora.{AgentConfig, Orchestrator.Runner, Orchestrator.TerminationCondition}

# Define agent configs -- each uses Echo :static mode with a different response
researcher_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "researcher",
  instructions: "You are a research assistant.",
  provider_opts: [echo_mode: :static, echo_response: "Research findings: The BEAM VM enables massive concurrency through lightweight processes."]
)

writer_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "writer",
  instructions: "You are a technical writer.",
  provider_opts: [echo_mode: :static, echo_response: "Article draft: Elixir's concurrency model, built on the BEAM VM, uses lightweight processes. FINAL ANSWER"]
)

agents = %{
  researcher: researcher_config,
  writer: writer_config
}

IO.puts("=== Multi-Agent Orchestration (RoundRobin) ===\n")

# Start the runner with RoundRobin orchestration and a keyword termination condition
{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.RoundRobin,
  agents: agents,
  termination: TerminationCondition.any_of([
    TerminationCondition.max_turns(3),
    TerminationCondition.keyword_match(["FINAL ANSWER"])
  ])
)

{:ok, response} = Runner.run(runner, "Research and write about BEAM concurrency")

IO.puts("Final response: #{response.content}")
IO.puts("\n[Orchestration complete]")

# Cleanup
Agora.stop_runner(runner)
