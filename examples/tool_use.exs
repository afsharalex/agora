# Tool Use Example
#
# Demonstrates an agent with Calculator and DateTime tools using
# the Echo provider in :function mode to simulate tool call cycles.
#
# Run with: mix run examples/tool_use.exs

alias Agora.{AgentConfig, Message, ToolCall}

# Use a counter to control the echo provider's multi-turn behavior
counter = :counters.new(1, [:atomics])

config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  instructions: "Use the calculator tool when asked math questions.",
  tools: [Agora.Tool.Calculator, Agora.Tool.DateTime],
  provider_opts: [
    echo_mode: :function,
    echo_function: fn messages, _config ->
      count = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      case count do
        0 ->
          # First turn: request a calculation
          {:ok,
           Message.assistant(nil, [
             ToolCall.new(%{
               id: "call_1",
               name: "calculator",
               arguments: %{"operation" => "multiply", "a" => 42, "b" => 17}
             })
           ])}

        1 ->
          # Second turn: request the current date
          {:ok,
           Message.assistant(nil, [
             ToolCall.new(%{
               id: "call_2",
               name: "current_datetime",
               arguments: %{"format" => "datetime"}
             })
           ])}

        _ ->
          # Third turn: summarize with tool results
          tool_results =
            messages
            |> Enum.filter(&(&1.role == :tool))
            |> Enum.flat_map(& &1.tool_results)
            |> Enum.map(fn r -> "#{r.name}: #{r.content}" end)
            |> Enum.join(", ")

          {:ok, Message.assistant("Here are the results -- #{tool_results}")}
      end
    end
  ]
)

IO.puts("=== Tool Use Example ===\n")
IO.puts("User: What is 42 * 17, and what time is it?\n")

{:ok, response} = Agora.run(config, "What is 42 * 17, and what time is it?")
IO.puts("Agent: #{response.content}")
