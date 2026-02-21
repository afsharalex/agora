# Plan Mode Orchestration Example
#
# Demonstrates autonomous plan-execute-review orchestration where a planner
# agent creates a structured plan, assigns steps to specialist workers, and
# reviews results before declaring completion.
#
# Run with: mix run examples/plan_mode.exs

alias Agora.{AgentConfig, Message}

# --- Helper to build agent configs with fresh counters ---
# Each demo section uses its own counter to avoid stale state.

defmodule PlanModeDemo do
  def build_agents do
    planner_counter = :counters.new(1, [:atomics])

    planner_fn = fn _messages, _config ->
      n = :counters.get(planner_counter, 1) + 1
      :counters.put(planner_counter, 1, n)

      case n do
        1 ->
          {:ok,
           Message.assistant("""
           I'll create a plan for this task.

           PLAN
           STEP:1:researcher:Research the key concepts of BEAM concurrency
           STEP:2:writer:Write a summary article based on the research:DEP:1
           END_PLAN
           """)}

        2 ->
          {:ok, Message.assistant("REVIEW:CONTINUE:Research looks good, proceed to writing")}

        3 ->
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

    %{planner: planner_config, researcher: researcher_config, writer: writer_config}
  end
end

# --- Part 1: Synchronous run_mode ---

IO.puts("=== Plan Mode Orchestration ===\n")
IO.puts("--- Part 1: Synchronous run_mode/3 ---\n")

agents = PlanModeDemo.build_agents()

{:ok, response} = Agora.run_mode(:plan, "Write an article about BEAM concurrency",
  agents: agents,
  orchestrator_opts: [planner_agent: :planner]
)

IO.puts("Final result: #{String.slice(response.content, 0, 120)}...")

# --- Part 2: Streaming with run_mode_stream ---

IO.puts("\n--- Part 2: Streaming with run_mode_stream/3 ---\n")

# Fresh agents with new counter to avoid stale planner state
stream_agents = PlanModeDemo.build_agents()

{:ok, stream} = Agora.run_mode_stream(:plan, "Write an article about BEAM concurrency",
  agents: stream_agents,
  orchestrator_opts: [planner_agent: :planner]
)

for event <- stream do
  case event.type do
    :mode_started -> IO.puts("  [stream] Execution started")
    :agent_selected -> IO.puts("  [stream] Agent selected: #{event.data.agent}")
    :step_completed -> IO.puts("  [stream] Step completed (turn #{event.data.turn})")
    :mode_completed -> IO.puts("  [stream] Done in #{event.data.turns} turns")
    :done -> :ok
    _ -> :ok
  end
end

IO.puts("\n[Plan mode orchestration complete]")
