# Agent Parallel Composition Example
#
# Demonstrates Agora.parallel/3 — agents run concurrently and independently.
# Each agent receives the same input. Uses the Echo provider (no API key needed).
#
# Run with: mix run examples/agent_parallel.exs

sentiment = Agora.agent(:echo, "echo",
  name: "sentiment",
  instructions: "You analyze sentiment."
)

keywords = Agora.agent(:echo, "echo",
  name: "keywords",
  instructions: "You extract keywords."
)

summary = Agora.agent(:echo, "echo",
  name: "summary",
  instructions: "You write concise summaries."
)

IO.puts("=== Agent Parallel Composition ===\n")

{:ok, results} = Agora.parallel("The BEAM VM enables massive concurrency through lightweight processes.", [
  sentiment: sentiment,
  keywords: keywords,
  summary: summary
])

Enum.each(results, fn {step, result} ->
  case result do
    {:ok, msg} -> IO.puts("[#{step}] #{msg.content}")
    {:error, err} -> IO.puts("[#{step}] Error: #{err}")
  end
end)

IO.puts("\n[Parallel composition complete]")
