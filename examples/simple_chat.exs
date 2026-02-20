# Simple Chat Example
#
# Demonstrates one-shot agent execution using Agora.run/2.
# Uses the Echo provider by default (no API key needed).
#
# Run with: mix run examples/simple_chat.exs
#
# To use a real provider, replace the config:
#
#   config = Agora.AgentConfig.new!(
#     provider: :anthropic,
#     model: "claude-sonnet-4-20250514",
#     instructions: "You are a helpful assistant."
#   )

alias Agora.AgentConfig

config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  instructions: "You are a helpful assistant."
)

IO.puts("=== Simple Chat (One-Shot) ===\n")

{:ok, response} = Agora.run(config, "Hello! What is Elixir?")
IO.puts("User: Hello! What is Elixir?")
IO.puts("Agent: #{response.content}")
IO.puts("\nMetadata: #{inspect(response.metadata)}")
