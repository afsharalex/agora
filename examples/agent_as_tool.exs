# Agent-as-Tool: Hierarchical agent composition
#
# Demonstrates using one agent as a tool for another agent.
# The supervisor agent can delegate tasks to the research agent.
# Uses the Echo provider — no API key needed.
#
# Run: mix run examples/agent_as_tool.exs

alias Agora.AgentConfig

# Define a child agent
researcher = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "researcher",
  instructions: "You are a research specialist."
)

# Wrap it as a tool
research_tool = Agora.agent_tool(researcher,
  name: "research_agent",
  description: "Delegates research tasks to a specialized research agent."
)

# Define a parent agent that uses the child as a tool
supervisor = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "supervisor",
  instructions: "You are a supervisor. Use research_agent for research tasks.",
  tools: [research_tool]
)

# Run the supervisor — it will echo back the input
# (In a real scenario with a live LLM, it would decide to call the research_agent tool)
{:ok, result} = Agora.run(supervisor, "Research the BEAM virtual machine")

IO.puts("=== Agent-as-Tool Result ===")
IO.puts("Supervisor response: #{result.content}")
