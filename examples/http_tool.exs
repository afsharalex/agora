# HTTP Tool Example
#
# Demonstrates the Http tool for making API requests with SSRF protection.
# An agent uses the Http tool to fetch data from httpbin.org (a public test API),
# posts data back, and summarizes the results.
#
# Requires network access.
#
# Run with: mix run examples/http_tool.exs

alias Agora.{AgentConfig, Message, ToolCall}

# Counter-driven echo function for multi-turn tool calls
counter = :counters.new(1, [:atomics])

config =
  AgentConfig.new!(
    provider: :echo,
    model: "echo",
    instructions: "You are an API tester. Use the http tool to interact with web APIs.",
    tools: [Agora.Tool.Http],
    provider_opts: [
      echo_mode: :function,
      echo_function: fn messages, _config ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        case count do
          0 ->
            # Turn 1: GET request to fetch JSON data
            {:ok,
             Message.assistant(nil, [
               ToolCall.new(%{
                 id: "call_1",
                 name: "http",
                 arguments: %{
                   "method" => "get",
                   "url" => "https://httpbin.org/json"
                 }
               })
             ])}

          1 ->
            # Turn 2: POST request with JSON body
            {:ok,
             Message.assistant(nil, [
               ToolCall.new(%{
                 id: "call_2",
                 name: "http",
                 arguments: %{
                   "method" => "post",
                   "url" => "https://httpbin.org/post",
                   "headers" => %{"content-type" => "application/json"},
                   "body" => Jason.encode!(%{"name" => "Alice", "role" => "engineer"})
                 }
               })
             ])}

          _ ->
            # Turn 3: Summarize results from tool history
            tool_results =
              messages
              |> Enum.filter(&(&1.role == :tool))
              |> Enum.flat_map(& &1.tool_results)

            get_status =
              Enum.find_value(tool_results, "unknown", fn r ->
                if r.tool_call_id == "call_1" do
                  case Jason.decode(r.content) do
                    {:ok, %{"status" => s}} -> "#{s}"
                    _ -> r.content
                  end
                end
              end)

            post_status =
              Enum.find_value(tool_results, "unknown", fn r ->
                if r.tool_call_id == "call_2" do
                  case Jason.decode(r.content) do
                    {:ok, %{"status" => s}} -> "#{s}"
                    _ -> r.content
                  end
                end
              end)

            {:ok,
             Message.assistant(
               "API testing complete! " <>
                 "GET /json returned status #{get_status}. " <>
                 "POST /post returned status #{post_status}. " <>
                 "Both endpoints responded successfully — SSRF protection allowed " <>
                 "these requests because httpbin.org resolves to a public IP."
             )}
        end
      end
    ]
  )

IO.puts("=== HTTP Tool Example ===\n")
IO.puts("User: Test the httpbin.org API — fetch some JSON and post data back.\n")

{:ok, response} = Agora.run(config, "Test the httpbin.org API with GET and POST requests.")
IO.puts("Agent: #{response.content}")
