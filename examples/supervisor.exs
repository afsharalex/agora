# Supervisor Orchestration Example
#
# Demonstrates delegation orchestration using Agora.supervisor/4.
# A manager agent delegates tasks to specialist workers via DELEGATE:name:message.
#
# Run with: mix run examples/supervisor.exs

alias Agora.Message

# The manager uses :function mode with a counter to simulate delegation behavior
manager_counter = :counters.new(1, [:atomics])

manager_fn = fn _messages, _config ->
  n = :counters.get(manager_counter, 1) + 1
  :counters.put(manager_counter, 1, n)

  case n do
    1 ->
      {:ok, Message.assistant("DELEGATE:analyst:Analyze the performance characteristics of GenServer")}

    2 ->
      {:ok, Message.assistant("Based on the analysis, GenServer provides sequential message processing with fault tolerance through supervision trees.")}

    _ ->
      {:ok, Message.assistant("Task complete.")}
  end
end

manager = Agora.agent(:echo, "echo",
  name: "manager",
  instructions: "You delegate tasks to specialists.",
  provider_opts: [echo_mode: :function, echo_function: manager_fn]
)

analyst = Agora.agent(:echo, "echo",
  name: "analyst",
  instructions: "You are a performance analyst.",
  provider_opts: [
    echo_mode: :static,
    echo_response: "Analysis: GenServer processes messages sequentially from a mailbox. Response time depends on message queue depth and processing time per message. Supervision trees restart crashed processes automatically."
  ]
)

writer = Agora.agent(:echo, "echo",
  name: "writer",
  instructions: "You are a technical writer.",
  provider_opts: [echo_mode: :static, echo_response: "Documentation draft ready."]
)

IO.puts("=== Supervisor Orchestration (Delegation) ===\n")

{:ok, response} = Agora.supervisor(
  "Document GenServer performance characteristics",
  {:manager, manager},
  [analyst: analyst, writer: writer]
)

IO.puts("Final response: #{response.content}")
IO.puts("\n[Supervisor orchestration complete]")
