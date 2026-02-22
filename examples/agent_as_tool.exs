# Agent-as-Tool: Hierarchical agent composition
#
# Demonstrates using one agent as a tool for another agent.
# The supervisor agent delegates research tasks to a specialized research agent.
#
# Run: mix run examples/agent_as_tool.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

# Define a child agent
researcher =
  Agora.agent(:openai, "gpt-4o",
    name: "researcher",
    instructions:
      "You are a research specialist. Provide detailed, factual research findings on the topic you're given. Focus on key concepts, history, and technical details."
  )

# Wrap it as a tool
research_tool =
  Agora.agent_tool(researcher,
    name: "research_agent",
    description:
      "Delegates research tasks to a specialized research agent. Use this tool to get detailed research on any topic."
  )

# Define a parent agent that uses the child as a tool
supervisor =
  Agora.agent(:openai, "gpt-4o",
    name: "supervisor",
    instructions:
      "You are a supervisor. You MUST use the research_agent tool to research topics — never answer research questions from your own knowledge. After receiving the research results, synthesize them into a brief executive summary.",
    tools: [research_tool]
  )

IO.puts("=== Agent-as-Tool Example ===\n")

{:ok, result} = Agora.run(supervisor, "Research the BEAM virtual machine")

IO.puts("Supervisor response: #{result.content}")
