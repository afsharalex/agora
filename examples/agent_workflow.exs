# Agent-based workflow using AgentStep and Builder
#
# Demonstrates building a DAG workflow where each step is an agent.
# Uses OpenAI's gpt-4o-mini for both agents.
#
# Run: mix run examples/agent_workflow.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

alias Agora.Workflow.{AgentStep, Builder}

# Define agents
researcher =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "researcher",
    instructions:
      "You are a research analyst. Provide detailed, factual research on the given topic. Focus on key concepts, history, and technical details. Present findings as a structured brief."
  )

writer =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "writer",
    instructions:
      "You are a technical writer. Write a clear, engaging article based on the research provided. Do not invent facts — use only the material given."
  )

# Build step specs
research_spec =
  AgentStep.spec(:research, researcher,
    input_mapper: fn _results -> "Research the BEAM virtual machine" end
  )

writing_spec =
  AgentStep.spec(:writing, writer,
    inputs: [:research],
    input_mapper: fn results ->
      case results[:research] do
        {:ok, msg} -> "Write an article based on: #{msg.content}"
        _ -> "Write an article about the BEAM"
      end
    end
  )

# Build and run workflow
workflow =
  Builder.new()
  |> Builder.step(research_spec)
  |> Builder.step(writing_spec)
  |> Builder.build!()

{:ok, results} = Agora.run_workflow(workflow)

IO.puts("=== Agent Workflow Results ===\n")

Enum.each(results, fn {step_id, result} ->
  case result do
    {:ok, msg} ->
      IO.puts("[#{step_id}] #{msg.content}\n")

    {:error, error} ->
      IO.puts("[#{step_id}] Error: #{error}")
  end
end)
