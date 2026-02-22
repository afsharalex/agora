# Group Chat Orchestration Example
#
# Demonstrates shared-transcript deliberation using Agora.group_chat/3.
# All agents see the full conversation history.
#
# Run with: mix run examples/group_chat.exs

alias Agora.Orchestrator.TerminationCondition

optimist = Agora.agent(:echo, "echo",
  name: "optimist",
  instructions: "You always see the bright side.",
  provider_opts: [
    echo_mode: :static,
    echo_response: "I think this is a great opportunity! The BEAM's concurrency model is perfect for this."
  ]
)

skeptic = Agora.agent(:echo, "echo",
  name: "skeptic",
  instructions: "You question assumptions.",
  provider_opts: [
    echo_mode: :static,
    echo_response: "But have we considered the trade-offs? What about the learning curve? On balance, I agree. FINAL ANSWER"
  ]
)

pragmatist = Agora.agent(:echo, "echo",
  name: "pragmatist",
  instructions: "You focus on practical outcomes.",
  provider_opts: [
    echo_mode: :static,
    echo_response: "Let's look at what works in practice. Elixir has proven itself in production."
  ]
)

IO.puts("=== Group Chat Orchestration (Shared Transcript) ===\n")

{:ok, response} = Agora.group_chat(
  "Should we adopt Elixir for our next project?",
  [optimist: optimist, skeptic: skeptic, pragmatist: pragmatist],
  termination: TerminationCondition.any_of([
    TerminationCondition.max_turns(6),
    TerminationCondition.keyword_match(["FINAL ANSWER"])
  ])
)

IO.puts("Final response: #{response.content}")
IO.puts("\n[Group chat orchestration complete]")
