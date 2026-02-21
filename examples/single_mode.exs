# Single Mode Example
#
# Demonstrates the simplest orchestrator mode: a single agent, one turn.
# Equivalent to Agora.run/2 but through the unified run_mode/3 API.
#
# Run with: mix run examples/single_mode.exs

alias Agora.AgentConfig

config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "helper",
  instructions: "You are a helpful assistant."
)

IO.puts("=== Single Mode ===\n")

# run_mode(:single, ...) starts one agent, runs one turn, and cleans up.
# Compare with Agora.run(config, "Hello") which does the same without orchestration.
{:ok, response} = Agora.run_mode(:single, "Hello from Single Mode!",
  agents: %{helper: config}
)

IO.puts("Response: #{response.content}")
IO.puts("\n[Single mode complete]")
