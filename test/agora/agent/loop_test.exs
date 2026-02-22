defmodule Agora.Agent.LoopTest do
  use ExUnit.Case, async: true

  alias Agora.Agent.Loop
  alias Agora.Agent.Loop.{RunResult, State}
  alias Agora.{AgentConfig, Error, Message, ToolCall}
  alias Agora.Tool.FunctionTool

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  defp build_state(config, messages \\ [], opts \\ []) do
    %State{
      config: config,
      messages: messages,
      middleware_metadata: Keyword.get(opts, :middleware_metadata, %{}),
      iteration: Keyword.get(opts, :iteration, 0),
      on_messages_update: Keyword.get(opts, :on_messages_update, nil)
    }
  end

  describe "run/1 basic" do
    test "returns done with assistant response for simple echo" do
      config = echo_config()
      messages = [Message.user("Hello!")]
      state = build_state(config, messages)

      %RunResult{outcome: outcome, facts: facts} = Loop.run(state)

      assert {:done, %Message{role: :assistant, content: "Echo: Hello!"}} = outcome
      assert facts.final_response.content == "Echo: Hello!"
      assert facts.appended_messages == [facts.final_response]
      assert facts.tool_calls_made == []
      assert facts.tool_results == []
    end

    test "returns error from provider" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "API failed"
          ]
        )

      state = build_state(config, [Message.user("Hello")])

      %RunResult{outcome: outcome, facts: facts} = Loop.run(state)

      assert {:error, %Error{type: :provider_error, message: "API failed"}} = outcome
      assert facts.final_response == nil
    end
  end

  describe "run/1 tool calls" do
    test "executes tool calls and continues loop" do
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
                call =
                  ToolCall.new(%{id: "c1", name: "add", arguments: %{"a" => 2, "b" => 3}})

                {:ok, Message.assistant(nil, [call])}
              else
                {:ok, Message.assistant("Result: 5")}
              end
            end
          ]
        )

      state = build_state(config, [Message.user("Add 2+3")])

      %RunResult{outcome: outcome, state: final_state, facts: facts} = Loop.run(state)

      assert {:done, %Message{content: "Result: 5"}} = outcome
      assert final_state.iteration == 2
      assert length(facts.tool_calls_made) == 1
      assert hd(facts.tool_calls_made).name == "add"
      assert length(facts.tool_results) == 1
      assert hd(facts.tool_results).content == "5"
      assert facts.final_response.content == "Result: 5"
      # assistant + tool + assistant = 3 appended messages
      assert length(facts.appended_messages) == 3
    end
  end

  describe "run/1 iteration limit" do
    test "returns iteration_limit error when max reached" do
      noop_tool =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "ok"} end
        )

      config =
        echo_config(
          max_iterations: 2,
          tools: [noop_tool],
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

      state = build_state(config, [Message.user("Loop")])

      %RunResult{outcome: outcome} = Loop.run(state)

      assert {:error, %Error{type: :iteration_limit}} = outcome
    end
  end

  describe "run/1 on_messages_update callback" do
    test "calls on_messages_update at start of each iteration" do
      call_count = :counters.new(1, [:atomics])
      update_log = :ets.new(:update_log, [:ordered_set, :public])

      add_tool =
        FunctionTool.new!(
          name: "add",
          description: "Adds",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "42"} end
        )

      config =
        echo_config(
          tools: [add_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                call = ToolCall.new(%{id: "c1", name: "add", arguments: %{}})
                {:ok, Message.assistant(nil, [call])}
              else
                {:ok, Message.assistant("done")}
              end
            end
          ]
        )

      on_update = fn msgs ->
        :ets.insert(update_log, {System.monotonic_time(), length(msgs)})
      end

      state = build_state(config, [Message.user("Go")], on_messages_update: on_update)

      Loop.run(state)

      entries = :ets.tab2list(update_log)
      # Called at start of iteration 1 and iteration 2
      assert length(entries) == 2
      # First call: 1 message (user message)
      assert {_, 1} = Enum.at(entries, 0)
      # Second call: 1 (user) + 1 (assistant) + 1 (tool) = 3 messages
      assert {_, 3} = Enum.at(entries, 1)

      :ets.delete(update_log)
    end
  end

  describe "run/1 middleware path" do
    test "middleware hooks fire in correct order" do
      test_pid = self()

      middleware = fn ctx, next ->
        send(test_pid, {:hook, ctx.hook})
        next.(ctx)
      end

      config = echo_config(middleware: [middleware])
      state = build_state(config, [Message.user("Hello")])

      %RunResult{outcome: {:done, _}} = Loop.run(state)

      assert_receive {:hook, :before_provider_call}
      assert_receive {:hook, :after_provider_call}
    end

    test "middleware halt returns error" do
      halt_middleware = fn ctx, _next ->
        if ctx.hook == :before_provider_call do
          {:halt, "stopped"}
        else
          {:ok, ctx}
        end
      end

      config = echo_config(middleware: [halt_middleware])
      state = build_state(config, [Message.user("Hello")])

      %RunResult{outcome: outcome} = Loop.run(state)

      assert {:error, %Error{type: :middleware_error, message: "stopped"}} = outcome
    end
  end

  describe "run/1 tool_opts sandbox propagation" do
    test "sandbox from tool_opts is passed to tool context" do
      test_pid = self()

      spy_tool =
        FunctionTool.new!(
          name: "spy_sandbox",
          description: "Reports sandbox presence",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, ctx ->
            send(test_pid, {:tool_context, ctx})
            {:ok, "spied"}
          end
        )

      call_count = :counters.new(1, [:atomics])

      sandbox = %Agora.Tool.Sandbox{
        working_directory: "/tmp/test_workspace",
        allowed_paths: ["/tmp/test_workspace"],
        denied_paths: ["/tmp/test_workspace/secrets"]
      }

      config =
        echo_config(
          tools: [spy_tool],
          tool_opts: [sandbox: sandbox],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                call =
                  ToolCall.new(%{id: "c1", name: "spy_sandbox", arguments: %{}})

                {:ok, Message.assistant(nil, [call])}
              else
                {:ok, Message.assistant("done")}
              end
            end
          ]
        )

      state = build_state(config, [Message.user("Check sandbox")])

      %RunResult{outcome: {:done, _}} = Loop.run(state)

      assert_receive {:tool_context, ctx}
      assert %Agora.Tool.Sandbox{} = ctx.sandbox
      assert ctx.sandbox.working_directory == "/tmp/test_workspace"
      assert ctx.sandbox.allowed_paths == ["/tmp/test_workspace"]
      assert ctx.sandbox.denied_paths == ["/tmp/test_workspace/secrets"]
    end

    test "tool context has no sandbox when tool_opts is empty" do
      test_pid = self()

      spy_tool =
        FunctionTool.new!(
          name: "spy_no_sandbox",
          description: "Reports sandbox absence",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, ctx ->
            send(test_pid, {:tool_context, ctx})
            {:ok, "spied"}
          end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          tools: [spy_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                call =
                  ToolCall.new(%{id: "c1", name: "spy_no_sandbox", arguments: %{}})

                {:ok, Message.assistant(nil, [call])}
              else
                {:ok, Message.assistant("done")}
              end
            end
          ]
        )

      state = build_state(config, [Message.user("Check no sandbox")])

      %RunResult{outcome: {:done, _}} = Loop.run(state)

      assert_receive {:tool_context, ctx}
      refute Map.has_key?(ctx, :sandbox)
    end
  end

  describe "run/1 facts accumulation" do
    test "accumulates facts across multiple tool iterations" do
      add_tool =
        FunctionTool.new!(
          name: "add",
          description: "Adds",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "result"} end
        )

      mul_tool =
        FunctionTool.new!(
          name: "mul",
          description: "Multiplies",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "product"} end
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

              case count do
                1 ->
                  call = ToolCall.new(%{id: "c1", name: "add", arguments: %{}})
                  {:ok, Message.assistant(nil, [call])}

                2 ->
                  call = ToolCall.new(%{id: "c2", name: "mul", arguments: %{}})
                  {:ok, Message.assistant(nil, [call])}

                3 ->
                  {:ok, Message.assistant("all done")}
              end
            end
          ]
        )

      state = build_state(config, [Message.user("Go")])

      %RunResult{facts: facts} = Loop.run(state)

      assert length(facts.tool_calls_made) == 2
      assert Enum.map(facts.tool_calls_made, & &1.name) == ["add", "mul"]
      assert length(facts.tool_results) == 2
      assert facts.final_response.content == "all done"
      # 2 iterations with tools (assistant + tool each) + 1 final assistant = 5
      assert length(facts.appended_messages) == 5
    end
  end
end
