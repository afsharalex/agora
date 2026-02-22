# Agent-based workflow using AgentStep and Builder
#
# Demonstrates building a DAG workflow where each step is an agent.
# Uses the Echo provider — no API key needed.
#
# Run: mix run examples/agent_workflow.exs

alias Agora.{AgentConfig, Workflow.AgentStep, Workflow.Builder}

# Define agents
researcher = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "researcher",
  instructions: "You are a research analyst."
)

writer = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "writer",
  instructions: "You are a technical writer."
)

# Build step specs
research_spec = AgentStep.spec(:research, researcher,
  input_mapper: fn _results -> "Research the BEAM virtual machine" end
)

writing_spec = AgentStep.spec(:writing, writer,
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
      IO.puts("[#{step_id}] #{msg.content}")

    {:error, error} ->
      IO.puts("[#{step_id}] Error: #{error}")
  end
end)
