# Agent Sequential Composition Example
#
# Demonstrates Agora.sequential/3 — a pipeline where each agent builds on
# the previous agent's output. Uses the Echo provider (no API key needed).
#
# Run with: mix run examples/agent_sequential.exs

researcher = Agora.agent(:echo, "echo",
  name: "researcher",
  instructions: "You are a research analyst."
)

writer = Agora.agent(:echo, "echo",
  name: "writer",
  instructions: "You are a technical writer."
)

editor = Agora.agent(:echo, "echo",
  name: "editor",
  instructions: "You are an editor who polishes text."
)

IO.puts("=== Agent Sequential Composition ===\n")

{:ok, results} = Agora.sequential("Write about the BEAM virtual machine", [
  researcher: researcher,
  writer: writer,
  editor: editor
])

Enum.each(results, fn {step, result} ->
  case result do
    {:ok, msg} -> IO.puts("[#{step}] #{msg.content}")
    {:error, err} -> IO.puts("[#{step}] Error: #{err}")
  end
end)

IO.puts("\n[Sequential composition complete]")
