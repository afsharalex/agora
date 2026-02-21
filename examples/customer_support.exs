# Customer Support Triage Example
#
# Demonstrates the gen_statem lifecycle backend for agents with state-specific
# behavior. A support agent collects issue details, classifies severity, and
# routes to resolution — each state has its own instructions, tools, and
# transition triggers.
#
# Features shown:
#   - 5 lifecycle states with state-specific instructions and tools
#   - Tool-call transition: collect_info triggers greeting → collecting_info
#   - Tool-result transition with predicate: classify_issue severity check
#   - Message-match transitions with guard function
#   - on_enter / on_exit callbacks logging state changes
#   - Echo provider :function mode with counter for multi-turn simulation
#
# Run with: mix run examples/customer_support.exs

alias Agora.{Agent, AgentConfig, Message, ToolCall}
alias Agora.Agent.Lifecycle
alias Agora.Agent.Lifecycle.StateConfig
alias Agora.Tool.FunctionTool

# --- Domain tools (only available in specific states) ---

collect_info_tool = FunctionTool.new!(
  name: "collect_info",
  description: "Collect issue details from the customer",
  schema: %{"type" => "object", "properties" => %{"issue" => %{"type" => "string"}}},
  function: fn args, _ctx ->
    {:ok, "Collected: #{args["issue"]}"}
  end
)

classify_issue_tool = FunctionTool.new!(
  name: "classify_issue",
  description: "Classify the issue severity",
  schema: %{"type" => "object", "properties" => %{"severity" => %{"type" => "string"}}},
  function: fn args, _ctx ->
    {:ok, "Severity: #{args["severity"]}"}
  end
)

# --- Echo provider function ---
#
# Each Agent.run/2 executes a full reasoning loop, calling the provider
# multiple times: once for a tool call, then again after tool execution
# for the final text response. The counter tracks total provider calls.
#
# Counter mapping:
#   Run 1 (greeting):       0 → collect_info tool call, 1 → text response
#   Run 2 (collecting_info): 2 → classify_issue tool call, 3 → text response
#   Run 3 (triaging):       4 → text response (no tools)
#   Run 4 (resolving):      5 → text response with "resolved"

counter = :counters.new(1, [:atomics])

echo_function = fn _messages, _config ->
  turn = :counters.get(counter, 1)
  :counters.add(counter, 1, 1)

  case turn do
    0 ->
      # Run 1, call 1: call collect_info to gather issue details
      {:ok,
       Message.assistant(nil, [
         ToolCall.new(%{
           id: "call_1",
           name: "collect_info",
           arguments: %{"issue" => "Login page returns 500 error"}
         })
       ])}

    1 ->
      # Run 1, call 2: text after tool result
      {:ok, Message.assistant("I've collected your issue details. Let me classify the severity.")}

    2 ->
      # Run 2, call 1: call classify_issue
      {:ok,
       Message.assistant(nil, [
         ToolCall.new(%{
           id: "call_2",
           name: "classify_issue",
           arguments: %{"severity" => "high"}
         })
       ])}

    3 ->
      # Run 2, call 2: text after classification
      {:ok, Message.assistant("The issue has been classified as high severity.")}

    4 ->
      # Run 3: acknowledge and prepare resolution (triaging → resolving)
      {:ok, Message.assistant("I'm investigating the 500 error on the login service.")}

    5 ->
      # Run 4: resolution with "resolved" keyword (resolving → closed)
      {:ok,
       Message.assistant(
         "I've resolved the issue — the login service has been restarted. " <>
           "Your 500 error should be fixed now."
       )}

    _ ->
      {:ok, Message.assistant("Is there anything else I can help with?")}
  end
end

# --- Lifecycle configuration ---
#
# Transitions are evaluated after each run completes, using facts from
# that run only. First match wins — order matters!

lifecycle = Lifecycle.new!(
  initial_state: :greeting,
  states: %{
    greeting: %StateConfig{
      instructions: "Greet the customer and collect their issue using the collect_info tool.",
      tools: [collect_info_tool]
    },
    collecting_info: %StateConfig{
      instructions: "Classify the issue severity using the classify_issue tool.",
      tools: [classify_issue_tool]
    },
    triaging: %StateConfig{
      instructions: "The issue has been classified. Investigate and prepare a resolution."
    },
    resolving: %StateConfig{
      instructions: "Work on resolving the issue. Include 'resolved' when the fix is complete."
    },
    closed: %StateConfig{
      instructions: "The ticket is closed. Thank the customer."
    }
  },
  transitions: [
    # Tool-call trigger: collect_info advances from greeting
    %{from: :greeting, to: :collecting_info, trigger: {:tool_call, "collect_info"}, guard: nil},

    # Tool-result trigger with predicate: classify_issue result must contain "high"
    %{
      from: :collecting_info,
      to: :triaging,
      trigger:
        {:tool_result, "classify_issue",
         fn result -> String.contains?(result.content, "high") end},
      guard: nil
    },

    # Message-match trigger: any response advances from triaging
    %{
      from: :triaging,
      to: :resolving,
      trigger: {:message_match, fn msg -> msg.content != nil end},
      guard: nil
    },

    # Message-match + guard: "resolved" keyword plus guard ensuring substantive response
    %{
      from: :resolving,
      to: :closed,
      trigger:
        {:message_match,
         fn msg -> msg.content != nil and String.contains?(msg.content, "resolved") end},
      guard: fn ctx ->
        # Guard: only close if the run succeeded and the response is substantive
        match?({:done, _}, ctx.outcome) and
          ctx.facts.final_response != nil and
          String.length(ctx.facts.final_response.content || "") > 20
      end
    }
  ],
  on_enter: %{
    greeting: fn _from, _to -> IO.puts("  [lifecycle] Entering :greeting") end,
    collecting_info: fn _from, _to -> IO.puts("  [lifecycle] Entering :collecting_info") end,
    triaging: fn _from, _to -> IO.puts("  [lifecycle] Entering :triaging") end,
    resolving: fn _from, _to -> IO.puts("  [lifecycle] Entering :resolving") end,
    closed: fn _from, _to -> IO.puts("  [lifecycle] Entering :closed — ticket complete!") end
  },
  on_exit: %{
    resolving: fn _from, _to -> IO.puts("  [lifecycle] Exiting :resolving — issue handled") end
  }
)

# --- Agent configuration ---

config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  instructions: "You are a customer support triage agent.",
  lifecycle: lifecycle,
  provider_opts: [
    echo_mode: :function,
    echo_function: echo_function
  ]
)

# --- Run the support flow ---

IO.puts("=== Customer Support Triage Example ===\n")

{:ok, agent} = Agora.start_agent(config)

{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("Initial state: #{state}\n")

# Turn 1: Agent calls collect_info → transitions to :collecting_info
IO.puts("--- Turn 1: Customer reports issue ---")
IO.puts("  User: My login page is showing a 500 error")
{:ok, response} = Agent.run(agent, "My login page is showing a 500 error")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

# Turn 2: Agent calls classify_issue → result predicate checks severity → :triaging
IO.puts("--- Turn 2: Classifying severity ---")
IO.puts("  User: How bad is it?")
{:ok, response} = Agent.run(agent, "How bad is it?")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

# Turn 3: Message-match fires → transitions to :resolving
IO.puts("--- Turn 3: Investigating ---")
IO.puts("  User: Can you fix it?")
{:ok, response} = Agent.run(agent, "Can you fix it?")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

# Turn 4: "resolved" keyword + guard → transitions to :closed
IO.puts("--- Turn 4: Resolving ---")
IO.puts("  User: Please fix the issue")
{:ok, response} = Agent.run(agent, "Please fix the issue")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

Agora.stop_agent(agent)
IO.puts("Done!")
