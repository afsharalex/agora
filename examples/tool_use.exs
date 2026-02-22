# Tool Use Example
#
# Demonstrates an agent with Calculator and DateTime tools.
# The agent autonomously decides when to call tools based on the question.
#
# Run with: mix run examples/tool_use.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

config =
  Agora.agent(:openai, "gpt-4o",
    instructions:
      "You are a helpful assistant with access to calculator and datetime tools. Always use the calculator tool for math operations rather than computing answers yourself. Always use the current_datetime tool when asked about the time or date.",
    tools: [Agora.Tool.Calculator, Agora.Tool.DateTime]
  )

IO.puts("=== Tool Use Example ===\n")
IO.puts("User: What is 42 * 17, and what time is it?\n")

{:ok, response} = Agora.run(config, "What is 42 * 17, and what time is it?")
IO.puts("Agent: #{response.content}")
