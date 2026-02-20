defmodule Agora.AgentStreamIntegrationTest do
  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig, Message, StreamEvent, ToolCall, ToolResult}

  describe "multi-turn streaming with tools" do
    test "streams tool calls, executes tools, streams second response" do
      # First call: return tool call. Second call: return text.
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count == 0 do
                # First turn: stream a tool call
                send(
                  caller,
                  {Agora.Stream, ref, StreamEvent.tool_call_start("call_1", "search", 0)}
                )

                send(
                  caller,
                  {Agora.Stream, ref, StreamEvent.tool_call_delta("call_1", ~s({"q":"test"}))}
                )

                msg =
                  Message.assistant(nil, [
                    ToolCall.new(%{id: "call_1", name: "search", arguments: %{"q" => "test"}})
                  ])

                send(caller, {Agora.Stream, ref, StreamEvent.message_complete(msg)})
                send(caller, {Agora.Stream, ref, StreamEvent.done()})
              else
                # Second turn: stream text
                send(caller, {Agora.Stream, ref, StreamEvent.text_delta("Found ")})
                send(caller, {Agora.Stream, ref, StreamEvent.text_delta("results")})
                msg = Message.assistant("Found results")
                send(caller, {Agora.Stream, ref, StreamEvent.message_complete(msg)})
                send(caller, {Agora.Stream, ref, StreamEvent.done()})
              end
            end
          ],
          tools: [
            %Agora.Tool.FunctionTool{
              name: "search",
              description: "Search",
              schema: %{},
              function: fn %{"q" => query}, _ctx ->
                {:ok, "results for #{query}"}
              end
            }
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, stream} = Agent.stream_run(pid, "search for test")
      events = Enum.to_list(stream)

      # Should see tool call events from first turn
      tool_starts = Enum.filter(events, &(&1.type == :tool_call_start))
      assert length(tool_starts) >= 1

      # Should see tool_result events
      tool_results = Enum.filter(events, &(&1.type == :tool_result))
      assert length(tool_results) == 1
      assert %ToolResult{} = hd(tool_results).data

      # Should see text deltas from second turn
      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) >= 1

      # Last event is :done
      assert List.last(events).type == :done

      # Wait for state update
      Process.sleep(50)

      # Conversation history should have: user + assistant(tool_call) + tool_result + assistant(text)
      messages = Agent.get_messages(pid)
      roles = Enum.map(messages, & &1.role)
      assert :user in roles
      assert :assistant in roles
      assert :tool in roles
    end

    test "streaming with middleware modifying events" do
      # Middleware that uppercases text deltas
      upcase_mw = fn ctx, next ->
        if ctx.hook == :on_stream_event && ctx.stream_event.type == :text_delta do
          event = ctx.stream_event
          upper_text = String.upcase(event.data.text)
          new_event = %{event | data: %{text: upper_text}}
          next.(%{ctx | stream_event: new_event})
        else
          next.(ctx)
        end
      end

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          middleware: [upcase_mw]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, stream} = Agent.stream_run(pid, "hello")
      events = Enum.to_list(stream)

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      texts = Enum.map(text_deltas, & &1.data.text)

      # All text should be uppercased
      assert Enum.all?(texts, fn t -> t == String.upcase(t) end)
    end

    test "Enum.to_list collects all events" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, pid} = Agent.start_link(config: config)
      {:ok, stream} = Agent.stream_run(pid, "test")

      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      assert :text_delta in types
      assert :message_complete in types
      assert :done in types
    end

    test "Stream.filter and Stream.take compose" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, pid} = Agent.start_link(config: config)
      {:ok, stream} = Agent.stream_run(pid, "hello world")

      first_two_deltas =
        stream
        |> Elixir.Stream.filter(&(&1.type == :text_delta))
        |> Elixir.Stream.take(2)
        |> Enum.to_list()

      assert length(first_two_deltas) == 2
      assert Enum.all?(first_two_deltas, &(&1.type == :text_delta))
    end

    test "middleware on_stream_event can suppress events" do
      # Middleware that filters out text deltas
      filter_mw = fn ctx, next ->
        case ctx.hook do
          :on_stream_event ->
            if ctx.stream_event && ctx.stream_event.type == :text_delta do
              next.(%{ctx | stream_event: nil})
            else
              next.(ctx)
            end

          _ ->
            next.(ctx)
        end
      end

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          middleware: [filter_mw],
          provider_opts: [
            echo_mode: :stream,
            echo_stream_events: [
              StreamEvent.text_delta("hello"),
              StreamEvent.text_delta(" world"),
              StreamEvent.message_complete(Message.assistant("hello world")),
              StreamEvent.done()
            ]
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, stream} = Agent.stream_run(pid, "hello")
      events = Enum.to_list(stream)

      # No text deltas should reach the caller
      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert text_deltas == []

      # But message_complete and done should still arrive
      assert Enum.any?(events, &(&1.type == :message_complete))
      assert List.last(events).type == :done
    end
  end
end
