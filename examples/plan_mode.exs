# Plan Orchestration Example
#
# Demonstrates autonomous plan-execute-review orchestration using Agora.plan/4.
# A planner agent creates a structured plan, assigns steps to specialist workers,
# and reviews results before declaring completion.
#
# Run with: mix run examples/plan_mode.exs

alias Agora.Message

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

planner = Agora.agent(:echo, "echo",
  name: "planner",
  instructions: "You are a project planner that breaks tasks into steps.",
  provider_opts: [echo_mode: :function, echo_function: planner_fn]
)

researcher_fn = fn _messages, _config ->
  {:ok,
   Message.assistant(
     "Research findings: The BEAM VM uses lightweight processes (not OS threads) " <>
       "that are individually garbage collected. Each process has its own heap, " <>
       "enabling soft real-time guarantees."
   )}
end

researcher = Agora.agent(:echo, "echo",
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
       "to concurrency.\n\nBased on research: #{String.slice(context, 0, 100)}..."
   )}
end

writer = Agora.agent(:echo, "echo",
  name: "writer",
  instructions: "You are a technical writer.",
  provider_opts: [echo_mode: :function, echo_function: writer_fn]
)

IO.puts("=== Plan Orchestration ===\n")

{:ok, response} = Agora.plan(
  "Write an article about BEAM concurrency",
  {:planner, planner},
  [researcher: researcher, writer: writer]
)

IO.puts("Final result: #{String.slice(response.content, 0, 120)}...")
IO.puts("\n[Plan orchestration complete]")
