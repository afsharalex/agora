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
#
# Run with: mix run examples/order_processing.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

alias Agora.{Agent, AgentConfig}
alias Agora.Agent.Lifecycle
alias Agora.Agent.Lifecycle.StateConfig
alias Agora.Tool.FunctionTool

# --- Domain tools ---

add_item_tool =
  FunctionTool.new!(
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

submit_order_tool =
  FunctionTool.new!(
    name: "submit_order",
    description: "Submit the order for confirmation",
    schema: %{"type" => "object", "properties" => %{"total" => %{"type" => "string"}}},
    function: fn args, _ctx ->
      {:ok, "Order submitted — total: #{args["total"]}. Awaiting confirmation."}
    end
  )

# --- Lifecycle configuration ---

lifecycle =
  Lifecycle.new!(
    initial_state: :taking_order,
    states: %{
      taking_order: %StateConfig{
        instructions:
          "You are a food ordering agent taking the customer's order. Use the add_item tool for each item the customer requests (with the item name and quantity). When the customer is done ordering, use the submit_order tool with an estimated total price. You MUST use add_item before submit_order.",
        tools: [add_item_tool, submit_order_tool]
      },
      confirming: %StateConfig{
        instructions:
          "The order is submitted. Ask the customer to confirm. When they agree, include the word 'confirmed' in your response."
      },
      processing: %StateConfig{
        instructions:
          "The order is confirmed and being processed. Let the customer know their order is being prepared and include the word 'complete' in your response."
      },
      complete: %StateConfig{
        instructions:
          "The order is complete. Thank the customer and give an estimated delivery time."
      },
      cancelled: %StateConfig{
        instructions:
          "The order was cancelled due to timeout. Let the customer know they can try again."
      }
    },
    transitions: [
      %{
        from: :taking_order,
        to: :confirming,
        trigger: {:tool_call, "submit_order"},
        guard: fn ctx ->
          Enum.any?(ctx.facts.tool_calls_made, &(&1.name == "add_item"))
        end
      },
      %{from: :taking_order, to: :taking_order, trigger: {:tool_call, "add_item"}, guard: nil},
      %{
        from: :confirming,
        to: :processing,
        trigger:
          {:message_match,
           fn msg -> msg.content != nil and String.contains?(msg.content, "confirmed") end},
        guard: nil
      },
      %{from: :confirming, to: :cancelled, trigger: {:state_timeout, 5_000}, guard: nil},
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

IO.puts("=== Order Processing Example ===\n")
IO.puts("--- Part 1: Successful Order Flow ---\n")

config =
  AgentConfig.new!(
    provider: :openai,
    model: "gpt-4o",
    instructions: "You are a food ordering agent.",
    lifecycle: lifecycle
  )

{:ok, agent} = Agora.start_agent(config)

{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("Initial state: #{state}\n")

# Run 1: add_item → self-transition (stays in taking_order)
IO.puts("--- Run 1: Add first item ---")
IO.puts("  User: I'd like 2 Margherita Pizzas")
{:ok, response} = Agent.run(agent, "I'd like 2 Margherita Pizzas")
IO.puts("  Agent: #{response.content}")
{:ok, state} = Agent.get_lifecycle_state(agent)
IO.puts("  State: #{state}\n")

# Run 2: add_item + submit_order → guard passes → confirming
IO.puts("--- Run 2: Add item and submit ---")
IO.puts("  User: Add a Garlic Bread and that's everything, submit the order")
{:ok, response} = Agent.run(agent, "Add a Garlic Bread and that's everything, submit the order")
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

IO.puts("--- Part 2: Timeout Cancellation Demo ---\n")

config2 =
  AgentConfig.new!(
    provider: :openai,
    model: "gpt-4o",
    instructions:
      "You are a food ordering agent. When asked to order and submit, use the add_item tool first, then the submit_order tool.",
    lifecycle: lifecycle
  )

{:ok, agent2} = Agora.start_agent(config2)

# Submit order immediately → moves to :confirming with 5s timeout
IO.puts("  User: One espresso please, submit it right away")
{:ok, response} = Agent.run(agent2, "One espresso please, submit it right away")
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
