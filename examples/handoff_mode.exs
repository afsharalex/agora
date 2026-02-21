# Handoff Mode Orchestration Example
#
# Demonstrates decentralized baton-passing orchestration where agents decide
# who runs next by emitting handoff directives. A triage agent routes customer
# requests to the appropriate specialist, who completes the task.
#
# Run with: mix run examples/handoff_mode.exs

alias Agora.{AgentConfig, Message}

# --- Helper to build agent configs ---
# Each demo section gets fresh configs to avoid stale closure state.

defmodule HandoffModeDemo do
  def build_agents do
    triage_fn = fn _messages, _config ->
      {:ok,
       Message.new(:assistant, "This is a billing question. Routing to billing specialist.",
         metadata: %{
           handoff: %{
             target: "billing",
             message: "Customer is asking about a charge on their account from last month."
           }
         }
       )}
    end

    triage_config = AgentConfig.new!(
      provider: :echo,
      model: "echo",
      name: "triage",
      instructions: "You are a customer service triage agent. Route requests to the appropriate specialist.",
      provider_opts: [echo_mode: :function, echo_function: triage_fn]
    )

    support_fn = fn _messages, _config ->
      {:ok, Message.assistant("I can help with general support questions.")}
    end

    support_config = AgentConfig.new!(
      provider: :echo,
      model: "echo",
      name: "support",
      instructions: "You handle general support questions.",
      provider_opts: [echo_mode: :function, echo_function: support_fn]
    )

    billing_fn = fn _messages, _config ->
      {:ok,
       Message.assistant(
         "I've looked into your account. The charge from last month was for your " <>
           "annual subscription renewal. I've applied a 20% loyalty discount and " <>
           "the adjusted amount will appear on your next statement."
       )}
    end

    billing_config = AgentConfig.new!(
      provider: :echo,
      model: "echo",
      name: "billing",
      instructions: "You are a billing specialist who resolves payment issues.",
      provider_opts: [echo_mode: :function, echo_function: billing_fn]
    )

    %{triage: triage_config, support: support_config, billing: billing_config}
  end
end

# --- Part 1: Synchronous run_mode ---

IO.puts("=== Handoff Mode Orchestration ===\n")
IO.puts("--- Part 1: Synchronous run_mode/3 ---\n")

agents = HandoffModeDemo.build_agents()

{:ok, response} = Agora.run_mode(:handoff, "I have a question about a charge on my account",
  agents: agents,
  orchestrator_opts: [initial_agent: :triage]
)

IO.puts("Final result: #{response.content}")

# --- Part 2: Streaming with run_mode_stream ---

IO.puts("\n--- Part 2: Streaming with run_mode_stream/3 ---\n")

# Fresh agents to avoid stale state
stream_agents = HandoffModeDemo.build_agents()

{:ok, stream} = Agora.run_mode_stream(:handoff, "I have a question about a charge on my account",
  agents: stream_agents,
  orchestrator_opts: [initial_agent: :triage]
)

for event <- stream do
  case event.type do
    :mode_started -> IO.puts("  [stream] Execution started")
    :agent_selected -> IO.puts("  [stream] Agent selected: #{event.data.agent}")
    :handoff -> IO.puts("  [stream] Handoff: #{event.data.from} -> #{event.data.to}")
    :step_completed -> IO.puts("  [stream] Step completed (turn #{event.data.turn})")
    :mode_completed -> IO.puts("  [stream] Done in #{event.data.turns} turns")
    :done -> :ok
    _ -> :ok
  end
end

IO.puts("\n[Handoff mode orchestration complete]")
