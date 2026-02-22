# Single Agent Example
#
# Demonstrates the simplest execution: a single agent, one turn.
# Uses Agora.run/2 for one-shot agent execution.
#
# Run with: mix run examples/single_mode.exs

config = Agora.agent(:echo, "echo",
  name: "helper",
  instructions: "You are a helpful assistant."
)

IO.puts("=== Single Agent ===\n")

{:ok, response} = Agora.run(config, "Hello from Single Agent!")

IO.puts("Response: #{response.content}")
IO.puts("\n[Single agent complete]")
