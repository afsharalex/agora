# Streaming Example
#
# Demonstrates real-time token streaming using Agora.stream/2.
# Uses the Echo provider in :stream mode with explicit events.
#
# Run with: mix run examples/streaming.exs
#
# To use a real provider, replace the config:
#
#   config = Agora.AgentConfig.new!(
#     provider: :anthropic,
#     model: "claude-sonnet-4-20250514"
#   )

alias Agora.{AgentConfig, Message, StreamEvent}

config = AgentConfig.new!(
  provider: :echo,
  model: "echo",
  provider_opts: [
    echo_mode: :stream,
    echo_stream_delay: 50,
    echo_stream_events: [
      StreamEvent.text_delta("Hello"),
      StreamEvent.text_delta(" from"),
      StreamEvent.text_delta(" the"),
      StreamEvent.text_delta(" streaming"),
      StreamEvent.text_delta(" agent!"),
      StreamEvent.message_complete(Message.assistant("Hello from the streaming agent!")),
      StreamEvent.done()
    ]
  ]
)

IO.puts("=== Streaming Example ===\n")
IO.write("Agent: ")

{:ok, stream} = Agora.stream(config, "Hello!")

stream
|> Enum.each(fn event ->
  case event.type do
    :text_delta -> IO.write(event.data.text)
    :message_complete -> IO.puts("\n\n[Stream complete]")
    :done -> IO.puts("[Done]")
    _ -> :ok
  end
end)
