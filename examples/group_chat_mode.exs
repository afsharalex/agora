# Group Chat Mode Example
#
# Demonstrates shared-transcript deliberation using run_mode(:group_chat, ...).
# All agents see the full conversation history. GroupChat is an alias for ChatRoom.
#
# Run with: mix run examples/group_chat_mode.exs

alias Agora.{AgentConfig, Orchestrator.TerminationCondition}

optimist_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "optimist",
  instructions: "You always see the bright side.",
  provider_opts: [
    echo_mode: :static,
    echo_response: "I think this is a great opportunity! The BEAM's concurrency model is perfect for this. FINAL ANSWER"
  ]
)

skeptic_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "skeptic",
  instructions: "You question assumptions.",
  provider_opts: [
    echo_mode: :static,
    echo_response: "But have we considered the trade-offs? What about the learning curve?"
  ]
)

pragmatist_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "pragmatist",
  instructions: "You focus on practical outcomes.",
  provider_opts: [
    echo_mode: :static,
    echo_response: "Let's look at what works in practice. Elixir has proven itself in production."
  ]
)

agents = %{
  optimist: optimist_config,
  skeptic: skeptic_config,
  pragmatist: pragmatist_config
}

IO.puts("=== Group Chat Mode (Shared Transcript) ===\n")

{:ok, response} = Agora.run_mode(:group_chat, "Should we adopt Elixir for our next project?",
  agents: agents,
  termination: TerminationCondition.any_of([
    TerminationCondition.max_turns(3),
    TerminationCondition.keyword_match(["FINAL ANSWER"])
  ])
)

IO.puts("Final response: #{response.content}")
IO.puts("\n[Group chat mode complete]")
