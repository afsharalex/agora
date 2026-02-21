defmodule Agora.Agent.StreamLoopTest do
  use ExUnit.Case, async: true

  alias Agora.Agent.Loop.State
  alias Agora.Agent.StreamLoop
  alias Agora.{AgentConfig, Error, Message, StreamEvent}

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  defp build_state(config, messages, opts \\ []) do
    %State{
      config: config,
      messages: messages,
      middleware_metadata: Keyword.get(opts, :middleware_metadata, %{}),
      iteration: Keyword.get(opts, :iteration, 0),
      on_messages_update: Keyword.get(opts, :on_messages_update, nil)
    }
  end

  defp capturing_emit_fn do
    test_pid = self()
    ref = make_ref()
    emit_fn = fn event -> send(test_pid, {ref, event}) end
    {emit_fn, ref}
  end

  defp collect_events(ref, acc \\ []) do
    receive do
      {^ref, %StreamEvent{type: :done} = event} -> Enum.reverse([event | acc])
      {^ref, %StreamEvent{} = event} -> collect_events(ref, [event | acc])
    after
      5000 -> Enum.reverse(acc)
    end
  end

  describe "run/2 basic streaming" do
    test "emits text_delta, message_complete, and done events" do
      config = echo_config()
      state = build_state(config, [Message.user("Hello")])
      {emit_fn, ref} = capturing_emit_fn()

      result = StreamLoop.run(state, emit_fn)
      events = collect_events(ref)

      assert {:ok, _messages, %{iteration: 1}} = result

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0
      full_text = Enum.map_join(text_deltas, & &1.data.text)
      assert full_text == "Echo: Hello"

      assert Enum.any?(events, &(&1.type == :message_complete))
      assert List.last(events).type == :done
    end

    test "returns final messages including user and assistant" do
      config = echo_config()
      state = build_state(config, [Message.user("Hello")])
      {emit_fn, _ref} = capturing_emit_fn()

      {:ok, messages, _state_updates} = StreamLoop.run(state, emit_fn)

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant]
      assert List.last(messages).content == "Echo: Hello"
    end
  end

  describe "run/2 error handling" do
    test "provider error emits error and done events" do
      config =
        echo_config(provider_opts: [echo_mode: :error, echo_error_message: "stream failed"])

      state = build_state(config, [Message.user("test")])
      {emit_fn, ref} = capturing_emit_fn()

      result = StreamLoop.run(state, emit_fn)
      events = collect_events(ref)

      assert {:error, %Error{}, _messages} = result
      assert Enum.any?(events, &(&1.type == :error))
    end

    test "iteration limit emits error and done events" do
      counter = :counters.new(1, [:atomics])

      config =
        echo_config(
          max_iterations: 1,
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count == 0 do
                send(
                  caller,
                  {Agora.Stream, ref, StreamEvent.tool_call_start("call_1", "search", 0)}
                )

                send(
                  caller,
                  {Agora.Stream, ref, StreamEvent.tool_call_delta("call_1", ~s({}))}
                )

                msg =
                  Message.assistant(nil, [
                    Agora.ToolCall.new(%{id: "call_1", name: "search", arguments: %{}})
                  ])

                send(caller, {Agora.Stream, ref, StreamEvent.message_complete(msg)})
                send(caller, {Agora.Stream, ref, StreamEvent.done()})
              else
                send(caller, {Agora.Stream, ref, StreamEvent.text_delta("done")})
                msg = Message.assistant("done")
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
              function: fn _args, _ctx -> {:ok, "result"} end
            }
          ]
        )

      state = build_state(config, [Message.user("search")])
      {emit_fn, ref} = capturing_emit_fn()

      result = StreamLoop.run(state, emit_fn)
      events = collect_events(ref)

      assert {:error, %Error{type: :iteration_limit}, _} = result
      assert Enum.any?(events, &(&1.type == :error))
      assert List.last(events).type == :done
    end
  end

  describe "run/2 middleware" do
    test "on_stream_event middleware fires" do
      test_pid = self()

      middleware = fn ctx, next ->
        if ctx.hook == :on_stream_event do
          send(test_pid, {:stream_event, ctx.stream_event.type})
        end

        next.(ctx)
      end

      config = echo_config(middleware: [middleware])
      state = build_state(config, [Message.user("Hello")])
      {emit_fn, _ref} = capturing_emit_fn()

      StreamLoop.run(state, emit_fn)

      assert_receive {:stream_event, :text_delta}
    end
  end
end
