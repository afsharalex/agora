# Agent Parallel Composition Example
#
# Demonstrates Agora.parallel/3 — agents run concurrently and independently.
# Each agent receives the same input. Uses OpenAI's gpt-4o-mini.
#
# Run with: mix run examples/agent_parallel.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

sentiment =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "sentiment",
    instructions:
      "You analyze sentiment. Classify the input text as positive, negative, or neutral, and explain your reasoning in one sentence."
  )

keywords =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "keywords",
    instructions:
      "You extract keywords. List the 3-5 most important keywords or phrases from the input text, one per line."
  )

summary =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "summary",
    instructions: "You write concise summaries. Summarize the input text in exactly one sentence."
  )

IO.puts("=== Agent Parallel Composition ===\n")

{:ok, results} =
  Agora.parallel(
    "The BEAM VM enables massive concurrency through lightweight processes. Each process has its own heap and is individually garbage collected, enabling soft real-time guarantees even under heavy load.",
    sentiment: sentiment,
    keywords: keywords,
    summary: summary
  )

Enum.each(results, fn {step, result} ->
  case result do
    {:ok, msg} -> IO.puts("[#{step}] #{msg.content}\n")
    {:error, err} -> IO.puts("[#{step}] Error: #{err}")
  end
end)

IO.puts("[Parallel composition complete]")
