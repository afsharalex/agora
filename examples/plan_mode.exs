# Plan Mode Orchestration Example
#
# Demonstrates autonomous plan-execute-review orchestration where a planner
# agent creates a structured plan, assigns steps to specialist workers, and
# reviews results before declaring completion.
#
# Run with: mix run examples/plan_mode.exs

alias Agora.{AgentConfig, Message, Orchestrator.Runner}

# --- Agent configs ---
# The planner uses :function mode to simulate structured plan/review output.
# Workers use :function mode to simulate domain-specific work.

planner_counter = :counters.new(1, [:atomics])

planner_fn = fn _messages, _config ->
  n = :counters.get(planner_counter, 1) + 1
  :counters.put(planner_counter, 1, n)

  case n do
    1 ->
      # First call: output a structured plan
      {:ok,
       Message.assistant("""
       I'll create a plan for this task.

       PLAN
       STEP:1:researcher:Research the key concepts of BEAM concurrency
       STEP:2:writer:Write a summary article based on the research:DEP:1
       END_PLAN
       """)}

    2 ->
      # Review after researcher completes
      {:ok, Message.assistant("REVIEW:CONTINUE:Research looks good, proceed to writing")}

    3 ->
      # Review after writer completes
      {:ok, Message.assistant("REVIEW:COMPLETE:Article is well-written and covers all key points")}

    _ ->
      {:ok, Message.assistant("REVIEW:COMPLETE:Done")}
  end
end

planner_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "planner",
  instructions: "You are a project planner that breaks tasks into steps.",
  provider_opts: [echo_mode: :function, echo_function: planner_fn]
)

researcher_fn = fn _messages, _config ->
  {:ok,
   Message.assistant(
     "Research findings: The BEAM VM uses lightweight processes (not OS threads) " <>
       "that are individually garbage collected. Each process has its own heap, " <>
       "enabling soft real-time guarantees. The scheduler uses preemptive reduction " <>
       "counting to ensure fair CPU distribution across all processes."
   )}
end

researcher_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "researcher",
  instructions: "You are a technical researcher.",
  provider_opts: [echo_mode: :function, echo_function: researcher_fn]
)

writer_fn = fn messages, _config ->
  # The writer receives context from the researcher's output
  last_user = Enum.find(messages, &(&1.role == :user))
  context = if last_user, do: last_user.content, else: ""

  {:ok,
   Message.assistant(
     "Article: Understanding BEAM Concurrency\n\n" <>
       "The BEAM virtual machine powers Elixir and Erlang with a unique approach " <>
       "to concurrency. Unlike traditional threading models, BEAM uses lightweight " <>
       "processes that are individually garbage collected, enabling millions of " <>
       "concurrent processes with soft real-time guarantees.\n\n" <>
       "Based on research: #{String.slice(context, 0, 100)}..."
   )}
end

writer_config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  name: "writer",
  instructions: "You are a technical writer.",
  provider_opts: [echo_mode: :function, echo_function: writer_fn]
)

agents = %{
  planner: planner_config,
  researcher: researcher_config,
  writer: writer_config
}

IO.puts("=== Plan Mode Orchestration ===\n")

# Start the runner with Plan orchestration
{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.Plan,
  agents: agents,
  orchestrator_opts: [planner_agent: :planner]
)

{:ok, response} = Runner.run(runner, "Write an article about BEAM concurrency")

IO.puts("Final result: #{response.content}")

# Show the execution trace
history = Runner.get_history(runner)
IO.puts("\nExecution trace (#{length(history)} turns):")

for {turn, i} <- Enum.with_index(history) do
  content = case turn.output do
    {:ok, msg} -> String.slice(msg.content || "(nil)", 0, 60)
    {:error, err} -> "ERROR: #{err.message}"
  end

  IO.puts("  #{i + 1}. #{turn.agent}: #{content}...")
end

IO.puts("\n[Plan mode orchestration complete]")

# Cleanup
Agora.stop_runner(runner)
