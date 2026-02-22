# Simple Chat Example
#
# Demonstrates one-shot agent execution using Agora.run/2.
# The agent uses OpenAI's gpt-4o-mini to respond to a simple question.
#
# Run with: mix run examples/simple_chat.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

config =
  Agora.agent(:openai, "gpt-4o-mini",
    instructions: "You are a helpful assistant. Keep your answers concise."
  )

IO.puts("=== Simple Chat (One-Shot) ===\n")

{:ok, response} = Agora.run(config, "Hello! What is Elixir?")
IO.puts("User: Hello! What is Elixir?")
IO.puts("Agent: #{response.content}")
