# Group Chat Orchestration Example
#
# Demonstrates shared-transcript deliberation using Agora.group_chat/3.
# All agents see the full conversation history. Uses OpenAI's gpt-4o-mini.
#
# Run with: mix run examples/group_chat.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

alias Agora.Orchestrator.TerminationCondition

optimist =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "optimist",
    instructions:
      "You always see the bright side of things. Highlight benefits and opportunities. Keep responses to 2-3 sentences."
  )

skeptic =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "skeptic",
    instructions:
      "You question assumptions and consider risks. Keep responses to 2-3 sentences. When the group reaches a reasonable consensus, end your message with FINAL ANSWER."
  )

pragmatist =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "pragmatist",
    instructions:
      "You focus on practical outcomes and real-world evidence. Keep responses to 2-3 sentences."
  )

IO.puts("=== Group Chat Orchestration (Shared Transcript) ===\n")

{:ok, response} =
  Agora.group_chat(
    "Should we adopt Elixir for our next project?",
    [optimist: optimist, skeptic: skeptic, pragmatist: pragmatist],
    termination:
      TerminationCondition.any_of([
        TerminationCondition.max_turns(6),
        TerminationCondition.keyword_match(["FINAL ANSWER"])
      ])
  )

IO.puts("Final response: #{response.content}")
IO.puts("\n[Group chat orchestration complete]")
