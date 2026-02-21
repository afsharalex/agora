# Handoff Mode Orchestration Example
#
# Demonstrates decentralized baton-passing orchestration where agents decide
# who runs next by emitting handoff directives. A triage agent routes customer
# requests to the appropriate specialist, who completes the task.
#
# Run with: mix run examples/handoff_mode.exs

alias Agora.{AgentConfig, Message, Orchestrator.Runner}

# --- Agent configs ---
# Each agent uses :function mode to simulate domain-specific behavior.
# Triage hands off to the appropriate specialist via metadata handoff.

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

agents = %{
  triage: triage_config,
  support: support_config,
  billing: billing_config
}

IO.puts("=== Handoff Mode Orchestration ===\n")

# Start the runner with Handoff orchestration
{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.Handoff,
  agents: agents,
  orchestrator_opts: [initial_agent: :triage]
)

{:ok, response} = Runner.run(runner, "I have a question about a charge on my account")

IO.puts("Final result: #{response.content}\n")

# Show the execution trace
history = Runner.get_history(runner)
IO.puts("Execution trace (#{length(history)} turns):")

for {turn, i} <- Enum.with_index(history) do
  content = case turn.output do
    {:ok, msg} -> String.slice(msg.content || "(nil)", 0, 70)
    {:error, err} -> "ERROR: #{err.message}"
  end

  IO.puts("  #{i + 1}. #{turn.agent}: #{content}...")
end

IO.puts("\n[Handoff mode orchestration complete]")

# Cleanup
Agora.stop_runner(runner)
