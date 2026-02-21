# Order Processing Example
#
# Demonstrates the gen_statem lifecycle backend with state timeouts,
# multi-step tool interactions, and guard functions that inspect run facts.
# An order-taking agent walks through stages: taking an order, confirming,
# processing, and completing — with a timeout that auto-cancels if the
# customer doesn't confirm in time.
#
# Features shown:
#   - State timeout (5s on :confirming → auto-cancel)
#   - Tool-call transitions (add_item stays in state, submit_order advances)
#   - Message-match transitions
#   - Guard inspecting facts for prior tool calls
#   - on_enter / on_exit callbacks
#   - get_lifecycle_state/1 for querying the current FSM state
#   - Echo provider :function mode with counter
#
# Run with: mix run examples/order_processing.exs

alias Agora.{Agent, AgentConfig, Message, ToolCall}
alias Agora.Agent.Lifecycle
alias Agora.Agent.Lifecycle.StateConfig
alias Agora.Tool.FunctionTool

# --- Domain tools ---

add_item_tool = FunctionTool.new!(
  name: "add_item",
  description: "Add an item to the order",
  schema: %{
    "type" => "object",
    "properties" => %{
      "item" => %{"type" => "string"},
      "quantity" => %{"type" => "integer"}
    }
  },
  function: fn args, _ctx ->
    {:ok, "Added #{args["quantity"]}x #{args["item"]} to order"}
  end
)

submit_order_tool = FunctionTool.new!(
  name: "submit_order",
  description: "Submit the order for confirmation",
  schema: %{"type" => "object", "properties" => %{"total" => %{"type" => "string"}}},
  function: fn args, _ctx ->
    {:ok, "Order submitted — total: #{args["total"]}. Awaiting confirmation."}
  end
)

# --- Lifecycle configuration ---
#
# Transition order matters — submit_order is checked BEFORE add_item so that
# when both appear in the same run, submit takes precedence over the
# add_item self-transition.

lifecycle = Lifecycle.new!(
  initial_state: :taking_order,
  states: %{
    taking_order: %StateConfig{
      instructions: "Take the customer's order. Use add_item for each item, then submit_order when done.",
      tools: [add_item_tool, submit_order_tool]
    },
    confirming: %StateConfig{
      instructions: "The order is submitted. Ask the customer to confirm. Say 'confirmed' when they agree."
    },
    processing: %StateConfig{
      instructions: "The order is confirmed. Process it and include 'complete' in your response."
    },
    complete: %StateConfig{
      instructions: "The order is complete. Thank the customer."
    },
    cancelled: %StateConfig{
      instructions: "The order was cancelled due to timeout."
    }
  },
  transitions: [
    # submit_order advances to confirming — guard ensures items were actually added
    %{
      from: :taking_order,
      to: :confirming,
      trigger: {:tool_call, "submit_order"},
      guard: fn ctx ->
        Enum.any?(ctx.facts.tool_calls_made, &(&1.name == "add_item"))
      end
    },

    # add_item self-transition (only fires if submit_order didn't match above)
    %{from: :taking_order, to: :taking_order, trigger: {:tool_call, "add_item"}, guard: nil},

    # Customer confirmation
    %{
      from: :confirming,
      to: :processing,
      trigger:
        {:message_match,
         fn msg -> msg.content != nil and String.contains?(msg.content, "confirmed") end},
      guard: nil
    },

    # 5-second timeout on confirming → auto-cancel
    %{from: :confirming, to: :cancelled, trigger: {:state_timeout, 5_000}, guard: nil},

    # Processing complete
    %{
      from: :processing,
      to: :complete,
      trigger:
        {:message_match,
         fn msg -> msg.content != nil and String.contains?(msg.content, "complete") end},
      guard: nil
    }
  ],
  on_enter: %{
    taking_order: fn _from, _to -> IO.puts("  [lifecycle] Ready to take order") end,
    confirming: fn _from, _to -> IO.puts("  [lifecycle] Awaiting confirmation (5s timeout)") end,
    processing: fn _from, _to -> IO.puts("  [lifecycle] Processing order...") end,
    complete: fn _from, _to -> IO.puts("  [lifecycle] Order complete!") end,
    cancelled: fn _from, _to -> IO.puts("  [lifecycle] Order cancelled (timeout)") end
  },
  on_exit: %{
    confirming: fn _from, _to -> IO.puts("  [lifecycle] Confirmation window closed") end
  }
)

# ============================================================
# Part 1: Successful Order Flow
# ============================================================
#
# Counter mapping (each Agent.run makes 1+ provider calls):
#   Run 1: 0 → add_item tool call, 1 → text (self-transition, stays in taking_order)
#   Run 2: 2 → add_item tool call, 3 → submit_order tool call, 4 → text (→ confirming)
#   Run 3: 5 → text with "confirmed" (→ processing)
#   Run 4: 6 → text with "complete" (→ complete)

IO.puts("=== Order Processing Example ===\n")
IO.puts("--- Part 1: Successful Order Flow ---\n")

counter = :counters.new(1, [:atomics])

echo_function = fn _messages, _config ->
  turn = :counters.get(counter, 1)
  :counters.add(counter, 1, 1)

  case turn do
    0 ->
      # Run 1, call 1: add first item
      {:ok,
       Message.assistant(nil, [
         ToolCall.new(%{
           id: "call_1",
           name: "add_item",
           arguments: %{"item" => "Margherita Pizza", "quantity" => 2}
         })
       ])}

    1 ->
      # Run 1, call 2: text after adding item
      {:ok, Message.assistant("Added 2x Margherita Pizza. Anything else?")}

    2 ->
      # Run 2, call 1: add another item
      {:ok,
       Message.assistant(nil, [
         ToolCall.new(%{
           id: "call_2",
           name: "add_item",
           arguments: %{"item" => "Garlic Bread", "quantity" => 1}
         })
       ])}

    3 ->
      # Run 2, call 2: submit the order
      {:ok,
       Message.assistant(nil, [
         ToolCall.new(%{
           id: "call_3",
           name: "submit_order",
           arguments: %{"total" => "$27.50"}
         })
       ])}

    4 ->
      # Run 2, call 3: text after submission
      {:ok, Message.assistant("Order submitted! Total: $27.50. Please confirm.")}

    5 ->
      # Run 3: confirmation
      {:ok, Message.assistant("Your order is confirmed! Processing now.")}

    6 ->
      # Run 4: completion
      {:ok,
       Message.assistant(
         "Your order is complete — 2x Margherita Pizza and 1x Garlic Bread " <>
           "will arrive in 30 minutes!"
       )}

    _ ->
      {:ok, Message.assistant("Thanks for ordering!")}
  end
end

config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  instructions: "You are a food ordering agent.",
  lifecycle: lifecycle,
  provider_opts: [
    echo_mode: :function,
    echo_function: echo_function
  ]
)

{:ok, agent} = Agora.start_agent(config)

{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("Initial state: #{state}\n")

# Run 1: add_item only → self-transition (stays in taking_order)
IO.puts("--- Run 1: Add first item ---")
IO.puts("  User: I'd like 2 Margherita Pizzas")
{:ok, response} = Agent.run(agent, "I'd like 2 Margherita Pizzas")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state} (self-transition — still taking order)\n")

# Run 2: add_item + submit_order → guard passes → confirming
IO.puts("--- Run 2: Add item and submit ---")
IO.puts("  User: Add a Garlic Bread and submit the order")
{:ok, response} = Agent.run(agent, "Add a Garlic Bread and submit the order")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

# Run 3: "confirmed" message → processing
IO.puts("--- Run 3: Customer confirms ---")
IO.puts("  User: Yes, confirmed!")
{:ok, response} = Agent.run(agent, "Yes, confirmed!")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

# Run 4: "complete" message → complete
IO.puts("--- Run 4: Order processed ---")
IO.puts("  User: How long until delivery?")
{:ok, response} = Agent.run(agent, "How long until delivery?")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

Agora.stop_agent(agent)

# ============================================================
# Part 2: Timeout Cancellation Demo
# ============================================================
#
# Submit an order but don't confirm — the 5-second state timeout
# on :confirming fires and auto-transitions to :cancelled.

IO.puts("--- Part 2: Timeout Cancellation Demo ---\n")

counter2 = :counters.new(1, [:atomics])

echo_function2 = fn _messages, _config ->
  turn = :counters.get(counter2, 1)
  :counters.add(counter2, 1, 1)

  case turn do
    0 ->
      # Add item and submit in one turn (both tool calls at once)
      {:ok,
       Message.assistant(nil, [
         ToolCall.new(%{
           id: "call_a",
           name: "add_item",
           arguments: %{"item" => "Espresso", "quantity" => 1}
         }),
         ToolCall.new(%{
           id: "call_b",
           name: "submit_order",
           arguments: %{"total" => "$4.50"}
         })
       ])}

    1 ->
      {:ok, Message.assistant("Order submitted for $4.50. Please confirm within 5 seconds.")}

    _ ->
      {:ok, Message.assistant("Your order was cancelled due to timeout.")}
  end
end

config2 = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  instructions: "You are a food ordering agent.",
  lifecycle: lifecycle,
  provider_opts: [
    echo_mode: :function,
    echo_function: echo_function2
  ]
)

{:ok, agent2} = Agora.start_agent(config2)

# Submit order immediately → moves to :confirming with 5s timeout
IO.puts("  User: One espresso please, submit it")
{:ok, response} = Agent.run(agent2, "One espresso please, submit it")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent2)
IO.puts("  State: #{state}")
IO.puts("  Waiting 6 seconds for timeout...\n")

# Wait for the 5-second state timeout to fire
Process.sleep(6_000)

{:ok, state} = Agent.get_lifecycle_state(agent2)
IO.puts("  State after timeout: #{state}\n")

Agora.stop_agent(agent2)
IO.puts("Done!")
