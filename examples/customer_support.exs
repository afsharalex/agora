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
#
# Run with: mix run examples/customer_support.exs
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

# --- Domain tools (only available in specific states) ---

collect_info_tool =
  FunctionTool.new!(
    name: "collect_info",
    description: "Collect issue details from the customer",
    schema: %{"type" => "object", "properties" => %{"issue" => %{"type" => "string"}}},
    function: fn args, _ctx ->
      {:ok, "Collected: #{args["issue"]}"}
    end
  )

classify_issue_tool =
  FunctionTool.new!(
    name: "classify_issue",
    description: "Classify the issue severity (low, medium, high, critical)",
    schema: %{"type" => "object", "properties" => %{"severity" => %{"type" => "string"}}},
    function: fn args, _ctx ->
      {:ok, "Severity: #{args["severity"]}"}
    end
  )

# --- Lifecycle configuration ---

lifecycle =
  Lifecycle.new!(
    initial_state: :greeting,
    states: %{
      greeting: %StateConfig{
        instructions:
          "You are a customer support agent greeting a customer. You MUST use the collect_info tool to record their issue. Extract the issue from the customer's message and pass it to the tool.",
        tools: [collect_info_tool]
      },
      collecting_info: %StateConfig{
        instructions:
          "You have collected the customer's issue. You MUST use the classify_issue tool to classify its severity. Based on the issue description, classify it as 'low', 'medium', 'high', or 'critical'. A server error or login failure is 'high' severity.",
        tools: [classify_issue_tool]
      },
      triaging: %StateConfig{
        instructions:
          "The issue has been classified. Investigate the issue and describe what you'll do to fix it. Be specific about your investigation steps."
      },
      resolving: %StateConfig{
        instructions:
          "Work on resolving the issue. Describe the fix you've applied and include the word 'resolved' in your response to indicate the fix is complete."
      },
      closed: %StateConfig{
        instructions:
          "The ticket is closed. Thank the customer and let them know the issue has been handled."
      }
    },
    transitions: [
      %{from: :greeting, to: :collecting_info, trigger: {:tool_call, "collect_info"}, guard: nil},
      %{
        from: :collecting_info,
        to: :triaging,
        trigger:
          {:tool_result, "classify_issue",
           fn result -> String.contains?(result.content, "high") end},
        guard: nil
      },
      %{
        from: :triaging,
        to: :resolving,
        trigger: {:message_match, fn msg -> msg.content != nil end},
        guard: nil
      },
      %{
        from: :resolving,
        to: :closed,
        trigger:
          {:message_match,
           fn msg -> msg.content != nil and String.contains?(msg.content, "resolved") end},
        guard: fn ctx ->
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

config =
  AgentConfig.new!(
    provider: :openai,
    model: "gpt-4o",
    instructions: "You are a customer support triage agent.",
    lifecycle: lifecycle
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
