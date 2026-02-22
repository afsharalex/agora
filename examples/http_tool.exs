# HTTP Tool Example
#
# Demonstrates the Http tool for making API requests with SSRF protection.
# An agent uses the Http tool to fetch data from httpbin.org (a public test API),
# posts data back, and summarizes the results.
#
# Requires network access.
#
# Run with: mix run examples/http_tool.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

config =
  Agora.agent(:openai, "gpt-4o",
    instructions: """
    You are an API tester. Use the http tool to interact with web APIs.
    Follow these steps:
    1. Make a GET request to https://httpbin.org/json to fetch sample JSON data
    2. Make a POST request to https://httpbin.org/post with a JSON body containing {"name": "Alice", "role": "engineer"} and a "content-type: application/json" header
    3. Summarize the results of both requests

    Note: The http tool has SSRF protection — requests to private/internal IPs are blocked.
    Public URLs like httpbin.org will work fine.
    """,
    tools: [Agora.Tool.Http]
  )

IO.puts("=== HTTP Tool Example ===\n")
IO.puts("User: Test the httpbin.org API — fetch some JSON and post data back.\n")

{:ok, response} = Agora.run(config, "Test the httpbin.org API with GET and POST requests.")
IO.puts("Agent: #{response.content}")
