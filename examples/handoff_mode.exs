# Handoff Orchestration Example
#
# Demonstrates decentralized baton-passing orchestration using Agora.handoff/3.
# A triage agent routes customer requests to the appropriate specialist.
#
# Run with: mix run examples/handoff_mode.exs

alias Agora.Message

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

triage = Agora.agent(:echo, "echo",
  name: "triage",
  instructions: "You are a customer service triage agent. Route requests to the appropriate specialist.",
  provider_opts: [echo_mode: :function, echo_function: triage_fn]
)

support_fn = fn _messages, _config ->
  {:ok, Message.assistant("I can help with general support questions.")}
end

support = Agora.agent(:echo, "echo",
  name: "support",
  instructions: "You handle general support questions.",
  provider_opts: [echo_mode: :function, echo_function: support_fn]
)

billing_fn = fn _messages, _config ->
  {:ok,
   Message.assistant(
     "I've looked into your account. The charge from last month was for your " <>
       "annual subscription renewal. I've applied a 20% loyalty discount."
   )}
end

billing = Agora.agent(:echo, "echo",
  name: "billing",
  instructions: "You are a billing specialist who resolves payment issues.",
  provider_opts: [echo_mode: :function, echo_function: billing_fn]
)

IO.puts("=== Handoff Orchestration ===\n")

{:ok, response} = Agora.handoff(
  "I have a question about a charge on my account",
  [triage: triage, support: support, billing: billing],
  initial: :triage
)

IO.puts("Final result: #{response.content}")
IO.puts("\n[Handoff orchestration complete]")
