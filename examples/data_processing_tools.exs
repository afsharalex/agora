# Data Processing Tools Example
#
# Demonstrates the Think, Json, and Regex tools for stateless data processing.
# An agent receives a JSON API response and contact text, then uses reasoning
# and extraction tools to analyze the data.
#
# Run with: mix run examples/data_processing_tools.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

api_response =
  Jason.encode!(%{
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

config =
  Agora.agent(:openai, "gpt-4o",
    instructions: """
    You are a data analyst. You have access to think, json, and regex tools.

    Use the think tool first to plan your approach.
    Use the json tool with operation "query" and a JSONPath expression to extract data from JSON.
    Use the regex tool with operation "scan" to find patterns in text.

    Always use the tools rather than parsing data yourself.
    """,
    tools: [Agora.Tool.Think, Agora.Tool.Json, Agora.Tool.Regex]
  )

IO.puts("=== Data Processing Tools Example ===\n")

prompt = """
Here is a JSON API response:
#{api_response}

Here is some contact text:
#{contact_text}

Please:
1. Use the json tool to get the first user's email from the API response (path: users[0].email)
2. Use the regex tool to extract all phone numbers (pattern: \\d{3}-\\d{3}-\\d{4}) from the contact text
3. Summarize your findings
"""

IO.puts("User: Analyze the API response and extract phone numbers from contact text.\n")

{:ok, response} = Agora.run(config, prompt)
IO.puts("Agent: #{response.content}")
