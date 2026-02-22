# Single Agent Example — Echo Provider (Testing Showcase)
#
# Demonstrates using the Echo provider for testing and CI environments.
# The Echo provider mirrors input back as output — no API key needed.
# Use this pattern in your test suites for deterministic, offline testing.
#
# Run with: mix run examples/single_agent.exs

config =
  Agora.agent(:echo, "echo",
    name: "helper",
    instructions: "You are a helpful assistant."
  )

IO.puts("=== Single Agent (Echo Provider — Testing) ===\n")

{:ok, response} = Agora.run(config, "Hello from Single Agent!")

IO.puts("Response: #{response.content}")
IO.puts("\n[Single agent complete]")
