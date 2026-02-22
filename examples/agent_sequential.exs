# Agent Sequential Composition Example
#
# Demonstrates Agora.sequential/3 — a pipeline where each agent builds on
# the previous agent's output. Each agent uses OpenAI's gpt-4o-mini.
#
# Run with: mix run examples/agent_sequential.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

researcher =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "researcher",
    instructions:
      "You are a research analyst. Gather key facts and concepts about the given topic. Present your findings as a structured research brief with bullet points."
  )

writer =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "writer",
    instructions:
      "You are a technical writer. Take the research brief provided and write a clear, engaging article. Use the facts from the research — do not invent new claims."
  )

editor =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "editor",
    instructions:
      "You are an editor who polishes text for clarity and flow. Fix grammar, tighten prose, and improve readability. Do not add new content — only refine what's given."
  )

IO.puts("=== Agent Sequential Composition ===\n")

{:ok, results} =
  Agora.sequential("Write about the BEAM virtual machine",
    researcher: researcher,
    writer: writer,
    editor: editor
  )

Enum.each(results, fn {step, result} ->
  case result do
    {:ok, msg} -> IO.puts("[#{step}] #{msg.content}\n")
    {:error, err} -> IO.puts("[#{step}] Error: #{err}")
  end
end)

IO.puts("[Sequential composition complete]")
