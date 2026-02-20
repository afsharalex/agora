defmodule Agora.AgentStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig, Error, Message, StreamEvent}

  defp start_agent(opts \\ []) do
    config = AgentConfig.new!(Keyword.merge([provider: :echo, model: "echo"], opts))
    {:ok, pid} = Agent.start_link(config: config)
    pid
  end

  describe "stream_run/2" do
    test "returns stream and delivers events" do
      pid = start_agent()
      {:ok, stream} = Agent.stream_run(pid, "Hello")

      events = Enum.to_list(stream)
      assert length(events) > 0

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0
      full_text = Enum.map_join(text_deltas, & &1.data.text)
      assert full_text == "Echo: Hello"

      assert Enum.any?(events, &(&1.type == :message_complete))
      assert List.last(events).type == :done
    end

    test "accepts string input" do
      pid = start_agent()
      {:ok, stream} = Agent.stream_run(pid, "Hi")
      events = Enum.to_list(stream)
      assert Enum.any?(events, &(&1.type == :text_delta))
    end

    test "accepts Message struct" do
      pid = start_agent()
      {:ok, stream} = Agent.stream_run(pid, Message.user("Hi"))
      events = Enum.to_list(stream)
      assert Enum.any?(events, &(&1.type == :text_delta))
    end

    test "status is :streaming before stream is consumed" do
      # Use explicit events with a delay to ensure status check happens during streaming
      test_pid = self()

      pid =
        start_agent(
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              # Signal test that streaming has started (via test_pid captured in closure)
              send(test_pid, :stream_started)

              # Wait for the test to check status
              receive do
                :continue -> :ok
              after
                5000 -> :ok
              end

              send(caller, {Agora.Stream, ref, StreamEvent.text_delta("hi")})

              send(
                caller,
                {Agora.Stream, ref, StreamEvent.message_complete(Message.assistant("hi"))}
              )

              send(caller, {Agora.Stream, ref, StreamEvent.done()})
            end
          ]
        )

      {:ok, stream} = Agent.stream_run(pid, "test")

      # Wait for the inner echo task to start and signal us
      assert_receive :stream_started, 5000

      # The agent GenServer should be in :streaming state
      assert Agent.get_status(pid) == :streaming

      # Let the stream continue
      send(stream.pid, :continue)

      _events = Enum.to_list(stream)

      # Wait for agent to return to idle
      Process.sleep(50)
      assert Agent.get_status(pid) == :idle
    end

    test "rejects concurrent run/2 while streaming" do
      test_pid = self()

      pid =
        start_agent(
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              send(test_pid, :stream_started)

              receive do
                :continue -> :ok
              after
                5000 -> :ok
              end

              send(caller, {Agora.Stream, ref, StreamEvent.done()})
            end
          ]
        )

      {:ok, stream} = Agent.stream_run(pid, "test")
      assert_receive :stream_started, 5000

      result = Agent.run(pid, "concurrent")
      assert {:error, %Error{type: :config_error}} = result

      send(stream.pid, :continue)
      _events = Enum.to_list(stream)
    end

    test "rejects concurrent stream_run/2 while streaming" do
      test_pid = self()

      pid =
        start_agent(
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              send(test_pid, :stream_started)

              receive do
                :continue -> :ok
              after
                5000 -> :ok
              end

              send(caller, {Agora.Stream, ref, StreamEvent.done()})
            end
          ]
        )

      {:ok, stream} = Agent.stream_run(pid, "test")
      assert_receive :stream_started, 5000

      result = Agent.stream_run(pid, "concurrent")
      assert {:error, %Error{type: :config_error}} = result

      send(stream.pid, :continue)
      _events = Enum.to_list(stream)
    end

    test "messages persisted after stream completes" do
      pid = start_agent()
      {:ok, stream} = Agent.stream_run(pid, "Hello")
      _events = Enum.to_list(stream)

      # Wait for GenServer state update
      Process.sleep(50)

      messages = Agent.get_messages(pid)
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assistant_msgs = Enum.filter(messages, &(&1.role == :assistant))

      assert length(user_msgs) == 1
      assert hd(user_msgs).content == "Hello"
      assert length(assistant_msgs) == 1
      assert assistant_msgs |> hd() |> Map.get(:content) == "Echo: Hello"
    end

    test "iteration limit in streaming loop" do
      counter = :counters.new(1, [:atomics])

      pid =
        start_agent(
          max_iterations: 1,
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

      {:ok, stream} = Agent.stream_run(pid, "search")
      events = Enum.to_list(stream)

      error_events = Enum.filter(events, &(&1.type == :error))
      assert length(error_events) > 0
      assert hd(error_events).data.type == :iteration_limit
    end

    test "error propagation from provider" do
      pid =
        start_agent(provider_opts: [echo_mode: :error, echo_error_message: "stream failed"])

      {:ok, stream} = Agent.stream_run(pid, "test")
      events = Enum.to_list(stream)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
    end

    test "middleware :on_stream_event hook fires" do
      test_pid = self()

      middleware = fn ctx, next ->
        if ctx.hook == :on_stream_event do
          send(test_pid, {:stream_event, ctx.stream_event.type})
        end

        next.(ctx)
      end

      pid = start_agent(middleware: [middleware])
      {:ok, stream} = Agent.stream_run(pid, "Hello")
      _events = Enum.to_list(stream)

      assert_receive {:stream_event, :text_delta}
    end

    test "Logger middleware handles :on_stream_event without halting" do
      pid = start_agent(middleware: [Agora.Middleware.Logger])
      {:ok, stream} = Agent.stream_run(pid, "Hello")
      events = Enum.to_list(stream)

      assert Enum.any?(events, &(&1.type == :text_delta))
      assert List.last(events).type == :done
    end

    test "stream_run telemetry events emitted" do
      test_pid = self()
      handler_id = "stream-test-#{inspect(make_ref())}"

      :telemetry.attach(
        handler_id,
        [:agora, :agent, :stream_run, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      pid = start_agent()
      {:ok, stream} = Agent.stream_run(pid, "Hello")
      _events = Enum.to_list(stream)

      assert_receive {:telemetry, [:agora, :agent, :stream_run, :start], %{system_time: _},
                      %{provider: :echo}}

      :telemetry.detach(handler_id)
    end

    test "custom provider without stream_chat returns streaming_error" do
      defmodule SyncOnlyProvider do
        @behaviour Agora.Provider

        @impl true
        def chat(_messages, _config) do
          {:ok, Agora.Message.assistant("sync only")}
        end
      end

      config = AgentConfig.new!(provider: SyncOnlyProvider, model: "test")
      {:ok, pid} = Agent.start_link(config: config)

      # run/2 works
      {:ok, response} = Agent.run(pid, "test")
      assert response.content == "sync only"

      # stream_run returns error via events
      {:ok, stream} = Agent.stream_run(pid, "test")
      events = Enum.to_list(stream)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
      assert error_event.data.type == :streaming_error
    end

    test "stream ownership: enumerating from wrong process raises" do
      pid = start_agent()
      {:ok, stream} = Agent.stream_run(pid, "Hello")

      task =
        Task.async(fn ->
          try do
            Enum.to_list(stream)
          rescue
            e in ArgumentError -> {:error, e.message}
          end
        end)

      result = Task.await(task)
      assert {:error, message} = result
      assert message =~ "owner process"
    end

    test "provider crash does not persist partial content in history" do
      counter = :counters.new(1, [:atomics])

      pid =
        start_agent(
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count == 0 do
                # Stream some text then crash (no :done sent)
                send(caller, {Agora.Stream, ref, StreamEvent.text_delta("partial")})
                # Simulate a crash by exiting
                Process.exit(self(), :kill)
              else
                send(caller, {Agora.Stream, ref, StreamEvent.text_delta("ok")})

                send(
                  caller,
                  {Agora.Stream, ref, StreamEvent.message_complete(Message.assistant("ok"))}
                )

                send(caller, {Agora.Stream, ref, StreamEvent.done()})
              end
            end
          ]
        )

      {:ok, stream} = Agent.stream_run(pid, "test")
      events = Enum.to_list(stream)

      # Should have received an error event
      assert Enum.any?(events, &(&1.type == :error))

      # Wait for state update
      Process.sleep(50)

      # Partial assistant content should NOT be in history
      messages = Agent.get_messages(pid)
      assistant_msgs = Enum.filter(messages, &(&1.role == :assistant))
      assert assistant_msgs == []

      # But user message should be there
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 1
    end

    test "middleware halt at :before_tool_call terminates stream with error" do
      counter = :counters.new(1, [:atomics])

      # Middleware that halts at :before_tool_call
      reject_tools = fn ctx, next ->
        case ctx.hook do
          :before_tool_call ->
            {:halt, Agora.Error.new(:middleware_error, "tools rejected")}

          _ ->
            next.(ctx)
        end
      end

      pid =
        start_agent(
          middleware: [reject_tools],
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count == 0 do
                # Stream a tool call
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

      {:ok, stream} = Agent.stream_run(pid, "search")
      events = Enum.to_list(stream)

      # Should have an error event from the middleware halt
      error_events = Enum.filter(events, &(&1.type == :error))
      assert length(error_events) > 0
      assert hd(error_events).data.type == :middleware_error

      # Stream should have terminated (Enumerable stops on :error — it's the terminal event)
      assert List.last(events).type == :error

      # Wait for GenServer state update
      Process.sleep(50)

      # History should NOT contain the partial assistant + tool messages
      messages = Agent.get_messages(pid)
      assistant_msgs = Enum.filter(messages, &(&1.role == :assistant))
      tool_msgs = Enum.filter(messages, &(&1.role == :tool))
      assert assistant_msgs == []
      assert tool_msgs == []

      # But user message should be there
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 1
    end
  end
end
