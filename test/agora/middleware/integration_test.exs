defmodule Agora.Middleware.IntegrationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Agora.{Agent, AgentConfig, Error, Message, ToolCall}
  alias Agora.Tool.FunctionTool
  alias Agora.Middleware.{Logger, MaxTokens, Timeout, ToolApproval}

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  defp add_tool do
    FunctionTool.new!(
      name: "add",
      description: "Adds two numbers",
      schema: %{"type" => "object", "properties" => %{}},
      function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, a + b} end
    )
  end

  defp tool_loop_config(opts \\ []) do
    call_count = :counters.new(1, [:atomics])

    defaults = [
      tools: [add_tool()],
      provider_opts: [
        echo_mode: :function,
        echo_function: fn _messages, _config ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count == 1 do
            call =
              ToolCall.new(%{
                id: "call_1",
                name: "add",
                arguments: %{"a" => 2, "b" => 3}
              })

            {:ok, Message.assistant(nil, [call])}
          else
            {:ok, Message.assistant("Result: done")}
          end
        end
      ]
    ]

    echo_config(Keyword.merge(defaults, opts))
  end

  describe "Agent + Logger" do
    test "runs successfully through full tool loop" do
      config = tool_loop_config(middleware: [Logger])

      log =
        capture_log(fn ->
          {:ok, pid} = Agent.start_link(config: config)
          assert {:ok, %Message{content: "Result: done"}} = Agent.run(pid, "Go")
        end)

      assert log =~ "before_provider_call"
      assert log =~ "after_provider_call"
      assert log =~ "before_tool_call"
      assert log =~ "after_tool_call"
    end
  end

  describe "Agent + MaxTokens" do
    test "halts when budget exceeded" do
      mw = MaxTokens.new(max_tokens: 1)

      config =
        echo_config(
          middleware: [mw],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              {:ok, Message.assistant("should not reach here")}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :middleware_error, message: msg}} =
               Agent.run(pid, String.duplicate("x", 100))

      assert msg =~ "Token budget exceeded"
    end

    test "passes when under budget" do
      mw = MaxTokens.new(max_tokens: 10_000)
      config = echo_config(middleware: [mw])

      {:ok, pid} = Agent.start_link(config: config)
      assert {:ok, %Message{}} = Agent.run(pid, "Hello")
    end
  end

  describe "Agent + Timeout" do
    test "halts after multi-iteration accumulation" do
      # Timeout of 0ms — will expire after first iteration
      mw = Timeout.new(timeout_ms: 0)

      noop_tool =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "ok"} end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          middleware: [mw],
          max_iterations: 10,
          tools: [noop_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count <= 5 do
                Process.sleep(1)

                call =
                  ToolCall.new(%{
                    id: "call_#{count}",
                    name: "noop",
                    arguments: %{}
                  })

                {:ok, Message.assistant(nil, [call])}
              else
                {:ok, Message.assistant("done")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      assert {:error, %Error{type: :timeout}} = Agent.run(pid, "Go")
    end
  end

  describe "Agent + ToolApproval" do
    test "blocks tool call → halt" do
      mw = ToolApproval.new(approve_fn: fn _calls -> {:reject, "not allowed"} end)
      config = tool_loop_config(middleware: [mw])

      {:ok, pid} = Agent.start_link(config: config)
      assert {:error, %Error{type: :middleware_error, message: msg}} = Agent.run(pid, "Go")
      assert msg =~ "rejected"
    end

    test "filters tool calls → only approved calls execute, history stays consistent" do
      # Two tool calls, approve only "add"
      mul_tool =
        FunctionTool.new!(
          name: "mul",
          description: "Multiplies",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "should not be called"} end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          tools: [add_tool(), mul_tool],
          middleware: [
            ToolApproval.new(
              approve_fn: fn calls ->
                {:filter, Enum.filter(calls, &(&1.name == "add"))}
              end
            )
          ],
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
      assert {:ok, %Message{content: "Done"}} = Agent.run(pid, "Go")

      # Verify history: assistant message should only have "add" tool_call
      messages = Agent.get_messages(pid)
      assistant_msg = Enum.find(messages, &(&1.role == :assistant && &1.tool_calls != []))
      assert length(assistant_msg.tool_calls) == 1
      assert hd(assistant_msg.tool_calls).name == "add"

      # Verify tool results only have one result
      tool_msg = Enum.find(messages, &(&1.role == :tool))
      assert length(tool_msg.tool_results) == 1
    end
  end

  describe "after_provider_call tool-call flow control" do
    test "middleware can add tool_calls to a no-tool-call response" do
      tool_called = :counters.new(1, [:atomics])

      noop_tool =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            :counters.add(tool_called, 1, 1)
            {:ok, "tool ran"}
          end
        )

      call_count = :counters.new(1, [:atomics])

      # Middleware injects a tool call at after_provider_call when provider returns none
      mw = fn
        %{hook: :after_provider_call} = ctx, next ->
          :counters.add(call_count, 1, 1)

          if :counters.get(call_count, 1) == 1 do
            injected = ToolCall.new(%{id: "injected_1", name: "noop", arguments: %{}})
            next.(%{ctx | tool_calls: [injected]})
          else
            next.(ctx)
          end

        ctx, next ->
          next.(ctx)
      end

      config =
        echo_config(
          middleware: [mw],
          tools: [noop_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              {:ok, Message.assistant("plain text response")}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, response} = Agent.run(pid, "Go")

      # Second iteration should return plain text (middleware doesn't inject on call 2)
      assert response.content == "plain text response"
      # The tool was called in the first iteration
      assert :counters.get(tool_called, 1) == 1
    end

    test "middleware can clear tool_calls to skip tool execution" do
      tool_called = :counters.new(1, [:atomics])

      noop_tool =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            :counters.add(tool_called, 1, 1)
            {:ok, "ok"}
          end
        )

      # Middleware clears tool_calls at after_provider_call
      mw = fn
        %{hook: :after_provider_call} = ctx, next ->
          next.(%{ctx | tool_calls: []})

        ctx, next ->
          next.(ctx)
      end

      config =
        echo_config(
          middleware: [mw],
          tools: [noop_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              call = ToolCall.new(%{id: "c1", name: "noop", arguments: %{}})
              {:ok, Message.assistant("with tools", [call])}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, response} = Agent.run(pid, "Go")

      # Response returned directly (no tool execution)
      assert response.content == "with tools"
      assert :counters.get(tool_called, 1) == 0

      # Stale tool_calls scrubbed from persisted response and history
      assert response.tool_calls == []

      messages = Agent.get_messages(pid)
      assistant_msgs = Enum.filter(messages, &(&1.role == :assistant))
      assert length(assistant_msgs) == 1
      assert hd(assistant_msgs).tool_calls == []
      # No :tool message since no tools ran
      refute Enum.any?(messages, &(&1.role == :tool))
    end
  end

  describe "multiple middleware compose" do
    test "multiple middleware execute in order" do
      order_tracker = :counters.new(3, [:atomics])

      mw1 = fn ctx, next ->
        :counters.add(order_tracker, 1, 1)
        next.(ctx)
      end

      mw2 = fn ctx, next ->
        :counters.add(order_tracker, 2, 1)
        next.(ctx)
      end

      mw3 = fn ctx, next ->
        :counters.add(order_tracker, 3, 1)
        next.(ctx)
      end

      config = echo_config(middleware: [mw1, mw2, mw3])
      {:ok, pid} = Agent.start_link(config: config)
      {:ok, _} = Agent.run(pid, "Hello")

      # All three were called (at least once, for before_provider_call + after_provider_call)
      assert :counters.get(order_tracker, 1) >= 1
      assert :counters.get(order_tracker, 2) >= 1
      assert :counters.get(order_tracker, 3) >= 1
    end
  end

  describe "halt persistence (D11)" do
    test "halt at before_provider_call → no provider call, no messages appended" do
      provider_called = :counters.new(1, [:atomics])

      mw = fn %{hook: :before_provider_call}, _next ->
        {:halt, Error.new(:middleware_error, "blocked")}
      end

      config =
        echo_config(
          middleware: [mw],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(provider_called, 1, 1)
              {:ok, Message.assistant("should not see this")}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:error, %Error{}} = Agent.run(pid, "Hello")

      # Provider was never called
      assert :counters.get(provider_called, 1) == 0

      # Only user message in history (from before the iteration)
      messages = Agent.get_messages(pid)
      assert [%Message{role: :user}] = messages
    end

    test "halt at after_provider_call → no tool execution, no messages appended" do
      tool_called = :counters.new(1, [:atomics])

      mw = fn
        %{hook: :after_provider_call}, _next ->
          {:halt, Error.new(:middleware_error, "blocked after provider")}

        ctx, next ->
          next.(ctx)
      end

      noop_tool =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            :counters.add(tool_called, 1, 1)
            {:ok, "ok"}
          end
        )

      config =
        echo_config(
          middleware: [mw],
          tools: [noop_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              call = ToolCall.new(%{id: "c1", name: "noop", arguments: %{}})
              {:ok, Message.assistant(nil, [call])}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:error, %Error{}} = Agent.run(pid, "Hello")

      assert :counters.get(tool_called, 1) == 0

      messages = Agent.get_messages(pid)
      assert [%Message{role: :user}] = messages
    end

    test "halt at before_tool_call → no tool execution, no messages appended" do
      tool_called = :counters.new(1, [:atomics])

      mw = fn
        %{hook: :before_tool_call}, _next ->
          {:halt, Error.new(:middleware_error, "blocked before tools")}

        ctx, next ->
          next.(ctx)
      end

      noop_tool =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            :counters.add(tool_called, 1, 1)
            {:ok, "ok"}
          end
        )

      config =
        echo_config(
          middleware: [mw],
          tools: [noop_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              call = ToolCall.new(%{id: "c1", name: "noop", arguments: %{}})
              {:ok, Message.assistant(nil, [call])}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:error, %Error{}} = Agent.run(pid, "Hello")

      assert :counters.get(tool_called, 1) == 0

      messages = Agent.get_messages(pid)
      assert [%Message{role: :user}] = messages
    end

    test "halt at after_tool_call → tool results discarded, no messages appended" do
      mw = fn
        %{hook: :after_tool_call}, _next ->
          {:halt, Error.new(:middleware_error, "blocked after tools")}

        ctx, next ->
          next.(ctx)
      end

      config = tool_loop_config(middleware: [mw])
      {:ok, pid} = Agent.start_link(config: config)
      {:error, %Error{}} = Agent.run(pid, "Hello")

      messages = Agent.get_messages(pid)
      assert [%Message{role: :user}] = messages
    end
  end

  describe "middleware metadata persistence" do
    test "metadata persists across iterations (Timeout deadline survives)" do
      mw = Timeout.new(timeout_ms: 60_000)
      config = tool_loop_config(middleware: [mw])

      {:ok, pid} = Agent.start_link(config: config)
      assert {:ok, %Message{content: "Result: done"}} = Agent.run(pid, "Go")
    end
  end

  describe "config modification (D7)" do
    test "config modification at before_provider_call affects provider call" do
      mw = fn
        %{hook: :before_provider_call} = ctx, next ->
          # Modify the instructions in config
          new_config = %{ctx.config | instructions: "Modified instructions"}
          next.(%{ctx | config: new_config})

        ctx, next ->
          next.(ctx)
      end

      config =
        echo_config(
          middleware: [mw],
          instructions: "Original instructions",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, config ->
              # The provider sees the modified config
              {:ok, Message.assistant("Instructions: #{config.instructions}")}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:ok, %Message{content: "Instructions: Modified instructions"}} =
               Agent.run(pid, "Go")
    end

    test "config modification does NOT persist to next iteration" do
      call_count = :counters.new(1, [:atomics])

      mw = fn
        %{hook: :before_provider_call} = ctx, next ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count == 1 do
            # First iteration: modify config
            new_config = %{ctx.config | instructions: "Modified"}
            next.(%{ctx | config: new_config})
          else
            # Second iteration: config should be back to original
            next.(ctx)
          end

        ctx, next ->
          next.(ctx)
      end

      noop_tool =
        FunctionTool.new!(
          name: "noop",
          description: "noop",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "ok"} end
        )

      provider_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          middleware: [mw],
          instructions: "Original",
          tools: [noop_tool],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, config ->
              :counters.add(provider_count, 1, 1)
              count = :counters.get(provider_count, 1)

              if count == 1 do
                assert config.instructions == "Modified"
                call = ToolCall.new(%{id: "c1", name: "noop", arguments: %{}})
                {:ok, Message.assistant(nil, [call])}
              else
                # Second iteration should have original config
                {:ok, Message.assistant("Instructions: #{config.instructions}")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      assert {:ok, %Message{content: "Instructions: Original"}} = Agent.run(pid, "Go")
    end
  end

  describe "empty middleware list regression" do
    test "identical behavior to pre-middleware agent" do
      config = echo_config(middleware: [])
      {:ok, pid} = Agent.start_link(config: config)

      assert {:ok, %Message{role: :assistant, content: "Echo: Hello!"}} = Agent.run(pid, "Hello!")

      messages = Agent.get_messages(pid)
      assert [%Message{role: :user}, %Message{role: :assistant}] = messages
    end

    test "tool loop works without middleware" do
      config = tool_loop_config(middleware: [])
      {:ok, pid} = Agent.start_link(config: config)
      assert {:ok, %Message{content: "Result: done"}} = Agent.run(pid, "Go")
    end
  end

  describe "middleware error handling in integration context" do
    test "middleware raise → agent returns clean error, stays alive" do
      mw = fn _ctx, _next -> raise "middleware crash" end
      config = echo_config(middleware: [mw])

      {:ok, pid} = Agent.start_link(config: config)
      assert {:error, %Error{type: :middleware_error, message: msg}} = Agent.run(pid, "Hello")
      assert msg =~ "raised"
      assert Process.alive?(pid)
      assert Agent.get_status(pid) == :idle
    end

    test "middleware throw → agent returns clean error, stays alive" do
      mw = fn _ctx, _next -> throw(:middleware_oops) end
      config = echo_config(middleware: [mw])

      {:ok, pid} = Agent.start_link(config: config)
      assert {:error, %Error{type: :middleware_error}} = Agent.run(pid, "Hello")
      assert Process.alive?(pid)
    end

    test "middleware exit → agent returns clean error, stays alive" do
      mw = fn _ctx, _next -> exit(:middleware_bye) end
      config = echo_config(middleware: [mw])

      {:ok, pid} = Agent.start_link(config: config)
      assert {:error, %Error{type: :middleware_error}} = Agent.run(pid, "Hello")
      assert Process.alive?(pid)
    end
  end

  describe "telemetry with middleware" do
    test "stop event emitted on middleware halt" do
      ref = make_ref()
      test_pid = self()
      agent_name = "telemetry_mw_test_#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        "mw-test-#{inspect(ref)}",
        [
          [:agora, :agent, :loop_iteration, :start],
          [:agora, :agent, :loop_iteration, :stop]
        ],
        fn event, measurements, metadata, _config ->
          if metadata[:agent_name] == agent_name do
            send(test_pid, {ref, event, measurements, metadata})
          end
        end,
        nil
      )

      mw = fn _ctx, _next ->
        {:halt, Error.new(:middleware_error, "halt for telemetry test")}
      end

      config = echo_config(middleware: [mw], name: agent_name)
      {:ok, pid} = Agent.start_link(config: config)
      {:error, _} = Agent.run(pid, "Hello")

      assert_receive {^ref, [:agora, :agent, :loop_iteration, :start], _, _}
      assert_receive {^ref, [:agora, :agent, :loop_iteration, :stop], %{duration: _}, meta}
      assert %Error{} = meta[:error]

      :telemetry.detach("mw-test-#{inspect(ref)}")
    end
  end
end
