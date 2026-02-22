# Handoff Orchestration Example
#
# Demonstrates decentralized baton-passing orchestration using Agora.handoff/3.
# A triage agent routes customer requests to the appropriate specialist using
# the HANDOFF:agent_name:message directive format.
#
# Run with: mix run examples/handoff.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

triage =
  Agora.agent(:openai, "gpt-4o",
    name: "triage",
    instructions: """
    You are a customer service triage agent. Your job is to route customer requests
    to the appropriate specialist.

    You have two specialists available: "support" and "billing".
    - Route billing/payment/charge questions to "billing"
    - Route general/technical issues to "support"

    To hand off to a specialist, your response MUST start with this exact format:
    HANDOFF:agent_name:context message for the specialist

    For example:
    HANDOFF:billing:Customer is asking about a charge on their account from last month.
    HANDOFF:support:Customer needs help resetting their password.

    Always hand off — never try to resolve the issue yourself.
    """
  )

support =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "support",
    instructions:
      "You are a general support specialist. Help customers with technical issues, account questions, and general inquiries. Be friendly and helpful."
  )

billing =
  Agora.agent(:openai, "gpt-4o-mini",
    name: "billing",
    instructions:
      "You are a billing specialist who resolves payment issues. Help customers understand charges, process refunds, and manage their subscription. Be empathetic and solution-oriented."
  )

IO.puts("=== Handoff Orchestration ===\n")

{:ok, response} =
  Agora.handoff(
    "I have a question about a charge on my account",
    [triage: triage, support: support, billing: billing],
    initial: :triage
  )

IO.puts("Final result: #{response.content}")
IO.puts("\n[Handoff orchestration complete]")
