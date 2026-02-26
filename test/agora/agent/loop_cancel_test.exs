defmodule Agora.Agent.LoopCancelTest do
  use ExUnit.Case, async: true

  alias Agora.Agent.Loop
  alias Agora.Agent.Loop.{RunResult, State}
  alias Agora.{AgentConfig, CancelToken, Error, Message}
  alias Agora.Tool.FunctionTool
  alias Agora.ToolCall

  defp echo_config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [provider: :echo, model: "echo", name: "cancel_loop_test"],
        opts
      )
    )
  end

  defp build_state(config, messages, opts \\ []) do
    %State{
      config: config,
      messages: messages,
      middleware_metadata: %{},
      iteration: 0,
      on_messages_update: nil,
      cancel_token: Keyword.get(opts, :cancel_token)
    }
  end

  describe "cancel at iteration boundary" do
    test "loop exits immediately when token is cancelled before start" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      config = echo_config()
      state = build_state(config, [Message.user("Hi")], cancel_token: token)

      %RunResult{outcome: outcome} = Loop.run(state)
      assert {:error, %Error{type: :cancelled}} = outcome
    end

    test "loop exits at iteration boundary when cancelled mid-loop" do
      token = CancelToken.new()
      call_count = :counters.new(1, [:atomics])

      tool =
        FunctionTool.new!(
          name: "noop",
          description: "No-op",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            # Cancel on first tool call, loop should check at next iteration
            CancelToken.cancel(token)
            {:ok, "done"}
          end
        )

      config =
        echo_config(
          tools: [tool],
          max_iterations: 5,
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                call = ToolCall.new(%{id: "c1", name: "noop", arguments: %{}})
                {:ok, Message.assistant(nil, [call])}
              else
                # Should never reach here — cancelled at iteration boundary
                {:ok, Message.assistant("Should not reach")}
              end
            end
          ]
        )

      state = build_state(config, [Message.user("Go")], cancel_token: token)
      %RunResult{outcome: outcome} = Loop.run(state)
      assert {:error, %Error{type: :cancelled}} = outcome
    end
  end

  describe "cancel before tool execution" do
    test "fast path: skips tool execution when cancelled after provider returns tool_calls" do
      token = CancelToken.new()

      tool =
        FunctionTool.new!(
          name: "slow_tool",
          description: "Slow tool",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            # Should never be called
            raise "Tool should not execute"
          end
        )

      config =
        echo_config(
          tools: [tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              # Cancel before tool execution
              CancelToken.cancel(token)
              call = ToolCall.new(%{id: "c1", name: "slow_tool", arguments: %{}})
              {:ok, Message.assistant(nil, [call])}
            end
          ]
        )

      state = build_state(config, [Message.user("Go")], cancel_token: token)
      %RunResult{outcome: outcome} = Loop.run(state)
      assert {:error, %Error{type: :cancelled, message: msg}} = outcome
      assert msg =~ "Cancelled before tool execution"
    end

    test "middleware path: skips tool execution when cancelled after provider returns" do
      token = CancelToken.new()

      tool =
        FunctionTool.new!(
          name: "slow_tool",
          description: "Slow tool",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            raise "Tool should not execute"
          end
        )

      noop_middleware = fn ctx, next -> next.(ctx) end

      config =
        echo_config(
          tools: [tool],
          middleware: [noop_middleware],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              CancelToken.cancel(token)
              call = ToolCall.new(%{id: "c1", name: "slow_tool", arguments: %{}})
              {:ok, Message.assistant(nil, [call])}
            end
          ]
        )

      state = build_state(config, [Message.user("Go")], cancel_token: token)
      %RunResult{outcome: outcome} = Loop.run(state)
      assert {:error, %Error{type: :cancelled}} = outcome
    end
  end

  describe "nil cancel_token" do
    test "zero-overhead path: loop runs normally without cancel_token" do
      config = echo_config()
      state = build_state(config, [Message.user("Hi")])

      assert is_nil(state.cancel_token)
      %RunResult{outcome: outcome} = Loop.run(state)
      assert {:done, %Message{}} = outcome
    end
  end
end
