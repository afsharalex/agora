# Streaming Example
#
# Demonstrates real-time token streaming using Agora.stream/2.
# Uses OpenAI's gpt-4o-mini for live streaming responses.
#
# Run with: mix run examples/streaming.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

config =
  Agora.agent(:openai, "gpt-4o-mini",
    instructions: "You are a helpful assistant. Keep your answers concise."
  )

IO.puts("=== Streaming Example ===\n")
IO.write("Agent: ")

{:ok, stream} = Agora.stream(config, "Explain pattern matching in Elixir in 3 sentences.")

stream
|> Enum.each(fn event ->
  case event.type do
    :text_delta -> IO.write(event.data.text)
    :message_complete -> IO.puts("\n\n[Stream complete]")
    :done -> IO.puts("[Done]")
    _ -> :ok
  end
end)
