# Data Processing Tools Example
#
# Demonstrates the Think, Json, and Regex tools for stateless data processing.
# An agent receives a JSON API response and uses reasoning + extraction tools
# to analyze it — no sandbox or filesystem access needed.
#
# Run with: mix run examples/data_processing_tools.exs

alias Agora.{AgentConfig, Message, ToolCall}

# Simulated API response with user data
api_response = Jason.encode!(%{
  "users" => [
    %{
      "name" => "Alice Chen",
      "email" => "alice@example.com",
      "phone" => "555-123-4567",
      "role" => "engineer"
    },
    %{
      "name" => "Bob Martinez",
      "email" => "bob.martinez@corp.io",
      "phone" => "555-987-6543",
      "role" => "designer"
    },
    %{
      "name" => "Carol Davis",
      "email" => "carol@example.com",
      "phone" => "555-246-8135",
      "role" => "engineer"
    }
  ]
})

contact_text = """
Reach us at 555-123-4567 or 555-987-6543. For emergencies call 555-246-8135.
Office line: 800-555-0199.
"""

# Counter-driven echo function to simulate a multi-turn tool call sequence
counter = :counters.new(1, [:atomics])

config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  instructions: "You are a data analyst. Use tools to process and analyze data.",
  tools: [Agora.Tool.Think, Agora.Tool.Json, Agora.Tool.Regex],
  provider_opts: [
    echo_mode: :function,
    echo_function: fn messages, _config ->
      count = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      case count do
        0 ->
          # Turn 1: Think about the approach
          {:ok,
           Message.assistant(nil, [
             ToolCall.new(%{
               id: "call_1",
               name: "think",
               arguments: %{
                 "thought" =>
                   "I need to: 1) Query the JSON to get the first user's email, " <>
                     "2) Use regex to extract all phone numbers from the contact text. " <>
                     "Let me start with the JSON query."
               }
             })
           ])}

        1 ->
          # Turn 2: Query JSON for the first user's email
          {:ok,
           Message.assistant(nil, [
             ToolCall.new(%{
               id: "call_2",
               name: "json",
               arguments: %{
                 "operation" => "query",
                 "input" => api_response,
                 "path" => "users[0].email"
               }
             })
           ])}

        2 ->
          # Turn 3: Extract phone numbers with regex
          {:ok,
           Message.assistant(nil, [
             ToolCall.new(%{
               id: "call_3",
               name: "regex",
               arguments: %{
                 "operation" => "scan",
                 "pattern" => "\\d{3}-\\d{3}-\\d{4}",
                 "input" => contact_text
               }
             })
           ])}

        _ ->
          # Turn 4: Summarize findings using tool results from message history
          tool_results =
            messages
            |> Enum.filter(&(&1.role == :tool))
            |> Enum.flat_map(& &1.tool_results)

          email =
            Enum.find_value(tool_results, "unknown", fn r ->
              if r.name == "json", do: r.content
            end)

          phone_count =
            Enum.find_value(tool_results, 0, fn r ->
              if r.name == "regex" do
                r.content |> Jason.decode!() |> length()
              end
            end)

          {:ok,
           Message.assistant(
             "Analysis complete! The first user's email is #{email}. " <>
               "I found #{phone_count} phone numbers in the contact text."
           )}
      end
    end
  ]
)

IO.puts("=== Data Processing Tools Example ===\n")
IO.puts("User: Analyze the API response — get the first user's email and extract phone numbers.\n")

{:ok, response} = Agora.run(config, "Analyze the API response and extract key data.")
IO.puts("Agent: #{response.content}")
