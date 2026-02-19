defmodule Agora.AgentTest do
  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig, Error, Message, ToolCall}
  alias Agora.Tool.FunctionTool

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  describe "start_link/1" do
    test "starts an agent process" do
      config = echo_config()
      assert {:ok, pid} = Agent.start_link(config: config)
      assert Process.alive?(pid)
    end

    test "status is :idle after start" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)
      assert Agent.get_status(pid) == :idle
    end

    test "system message in history when instructions present" do
      config = echo_config(instructions: "You are helpful.")
      {:ok, pid} = Agent.start_link(config: config)

      messages = Agent.get_messages(pid)
      assert [%Message{role: :system, content: "You are helpful."}] = messages
    end

    test "no system message when instructions empty" do
      config = echo_config(instructions: "")
      {:ok, pid} = Agent.start_link(config: config)
      assert Agent.get_messages(pid) == []
    end

    test "supports name registration" do
      config = echo_config()
      name = :"agent_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Agent.start_link(config: config, name: name)
      assert Agent.get_status(name) == :idle
    end
  end

  describe "run/2 with string input" do
    test "returns assistant message" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      assert {:ok, %Message{role: :assistant, content: "Echo: Hello!"}} =
               Agent.run(pid, "Hello!")
    end

    test "appends user and assistant messages to history" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      {:ok, _response} = Agent.run(pid, "Hello!")

      messages = Agent.get_messages(pid)
      assert [%Message{role: :user, content: "Hello!"}, %Message{role: :assistant}] = messages
    end

    test "status returns to :idle after run" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      {:ok, _} = Agent.run(pid, "Hello!")
      assert Agent.get_status(pid) == :idle
    end
  end

  describe "run/2 with Message struct" do
    test "accepts Message struct directly" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      msg = Message.user("Direct message")

      assert {:ok, %Message{role: :assistant, content: "Echo: Direct message"}} =
               Agent.run(pid, msg)
    end
  end

  describe "conversation persistence" do
    test "second run sees prior history" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              count = Enum.count(messages, &(&1.role == :user))
              {:ok, Message.assistant("Seen #{count} user messages")}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      {:ok, resp1} = Agent.run(pid, "First")
      assert resp1.content == "Seen 1 user messages"

      {:ok, resp2} = Agent.run(pid, "Second")
      assert resp2.content == "Seen 2 user messages"

      messages = Agent.get_messages(pid)
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end
  end

  describe "provider error propagation" do
    test "returns error from provider" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "API failed"
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :provider_error, message: "API failed"}} =
               Agent.run(pid, "Hello")
    end

    test "status returns to :idle after error" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "fail"
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:error, _} = Agent.run(pid, "Hello")
      assert Agent.get_status(pid) == :idle
    end
  end

  describe "crash protection" do
    test "provider raise is caught and returned as :unknown error" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              raise "provider exploded"
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :unknown, message: message}} =
               Agent.run(pid, "Hello")

      assert message =~ "provider exploded"
      assert Process.alive?(pid)
      assert Agent.get_status(pid) == :idle
    end

    test "provider exit is caught and returned as :unknown error" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              exit(:provider_crashed)
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :unknown, message: message}} =
               Agent.run(pid, "Hello")

      assert message =~ "exited"
      assert Process.alive?(pid)
    end

    test "provider throw is caught and returned as :unknown error" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              throw(:oops)
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :unknown, message: message}} =
               Agent.run(pid, "Hello")

      assert message =~ "threw"
      assert Process.alive?(pid)
    end

    test "crash error metadata is JSON-encodable" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              raise "kaboom"
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      {:error, %Error{} = error} = Agent.run(pid, "Hello")
      assert {:ok, _json} = Jason.encode(error)
      assert error.metadata.kind == "error"
      assert is_binary(error.metadata.reason)
    end

    test "crash after successful iterations preserves partial history" do
      add_tool =
        FunctionTool.new!(
          name: "add",
          description: "Adds",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, a + b} end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          tools: [add_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                # First iteration: return a tool call (succeeds)
                call =
                  ToolCall.new(%{
                    id: "c1",
                    name: "add",
                    arguments: %{"a" => 1, "b" => 2}
                  })

                {:ok, Message.assistant(nil, [call])}
              else
                # Second iteration: crash
                raise "mid-loop crash"
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      assert {:error, %Error{type: :unknown}} = Agent.run(pid, "Go")

      # History should include the user message, assistant tool_call, and tool results
      # from the first successful iteration
      messages = Agent.get_messages(pid)
      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :tool]
    end

    test "agent remains usable after crash" do
      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)

              if :counters.get(call_count, 1) == 1 do
                raise "first call crashes"
              else
                {:ok, Message.assistant("recovered")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{}} = Agent.run(pid, "Crash")
      assert {:ok, %Message{content: "recovered"}} = Agent.run(pid, "Retry")
    end
  end

  describe "concurrent run/2 queuing" do
    test "concurrent calls queue and both complete" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              # Small delay so second call arrives while first is processing
              Process.sleep(20)
              last_user = messages |> Enum.reverse() |> Enum.find(&(&1.role == :user))
              {:ok, Message.assistant("Reply to: #{last_user.content}")}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      task1 = Task.async(fn -> Agent.run(pid, "First") end)
      task2 = Task.async(fn -> Agent.run(pid, "Second") end)

      results = Task.await_many([task1, task2], 5000)

      assert [
               {:ok, %Message{content: "Reply to: First"}},
               {:ok, %Message{content: "Reply to: Second"}}
             ] = results

      # Both messages in history
      messages = Agent.get_messages(pid)
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end
  end

  describe "tool call loop" do
    test "executes tool calls and feeds results back" do
      add_tool =
        FunctionTool.new!(
          name: "add",
          description: "Adds two numbers",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, a + b} end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          tools: [add_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                tool_call =
                  ToolCall.new(%{
                    id: "call_1",
                    name: "add",
                    arguments: %{"a" => 2, "b" => 3}
                  })

                {:ok, Message.assistant(nil, [tool_call])}
              else
                # Second call — tool results should be in messages
                tool_msg = Enum.find(messages, &(&1.role == :tool))
                result = hd(tool_msg.tool_results)
                {:ok, Message.assistant("Result: #{result.content}")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, response} = Agent.run(pid, "Add 2 and 3")

      assert response.content == "Result: 5"

      messages = Agent.get_messages(pid)
      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :tool, :assistant]

      # Verify the assistant message has tool_calls
      assistant_msg = Enum.at(messages, 1)
      assert length(assistant_msg.tool_calls) == 1
      assert hd(assistant_msg.tool_calls).name == "add"
    end

    test "handles multiple tool calls in one turn" do
      add_tool =
        FunctionTool.new!(
          name: "add",
          description: "Adds",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, a + b} end
        )

      mul_tool =
        FunctionTool.new!(
          name: "mul",
          description: "Multiplies",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, a * b} end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          tools: [add_tool, mul_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                calls = [
                  ToolCall.new(%{id: "c1", name: "add", arguments: %{"a" => 1, "b" => 2}}),
                  ToolCall.new(%{id: "c2", name: "mul", arguments: %{"a" => 3, "b" => 4}})
                ]

                {:ok, Message.assistant(nil, calls)}
              else
                {:ok, Message.assistant("Done")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, response} = Agent.run(pid, "Compute")
      assert response.content == "Done"

      messages = Agent.get_messages(pid)
      tool_msg = Enum.find(messages, &(&1.role == :tool))
      assert length(tool_msg.tool_results) == 2
    end
  end

  describe "iteration limit" do
    test "returns error when iteration limit reached" do
      always_tool_call =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "ok"} end
        )

      config =
        echo_config(
          max_iterations: 2,
          tools: [always_tool_call],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              call =
                ToolCall.new(%{
                  id: "call_#{System.unique_integer([:positive])}",
                  name: "noop",
                  arguments: %{}
                })

              {:ok, Message.assistant(nil, [call])}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :iteration_limit}} = Agent.run(pid, "Loop forever")
    end

    test "status returns to :idle after iteration limit" do
      always_tool_call =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "ok"} end
        )

      config =
        echo_config(
          max_iterations: 1,
          tools: [always_tool_call],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              call =
                ToolCall.new(%{
                  id: "call_#{System.unique_integer([:positive])}",
                  name: "noop",
                  arguments: %{}
                })

              {:ok, Message.assistant(nil, [call])}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:error, _} = Agent.run(pid, "Loop")
      assert Agent.get_status(pid) == :idle
    end
  end

  describe "instructions with tool loop" do
    test "system message preserved through tool loop" do
      add_tool =
        FunctionTool.new!(
          name: "add",
          description: "Adds",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, a + b} end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          instructions: "Be precise.",
          tools: [add_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                call = ToolCall.new(%{id: "c1", name: "add", arguments: %{"a" => 1, "b" => 1}})
                {:ok, Message.assistant(nil, [call])}
              else
                system = Enum.find(messages, &(&1.role == :system))
                {:ok, Message.assistant("System: #{system.content}")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, response} = Agent.run(pid, "Go")
      assert response.content == "System: Be precise."
    end
  end

  describe "telemetry events" do
    test "emits run start/stop with sanitized metadata" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "test-#{inspect(ref)}",
        [
          [:agora, :agent, :run, :start],
          [:agora, :agent, :run, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      config = echo_config(provider_opts: [api_key: "sk-secret-123"])
      {:ok, pid} = Agent.start_link(config: config)
      {:ok, _} = Agent.run(pid, "Hello")

      assert_receive {^ref, [:agora, :agent, :run, :start], %{system_time: _}, start_meta}
      assert start_meta.provider == :echo
      assert start_meta.model == "echo"
      refute Map.has_key?(start_meta, :config)

      assert_receive {^ref, [:agora, :agent, :run, :stop], %{duration: _, iterations: 1},
                      stop_meta}

      assert stop_meta.provider == :echo
      refute Map.has_key?(stop_meta, :config)

      :telemetry.detach("test-#{inspect(ref)}")
    end
  end
end
