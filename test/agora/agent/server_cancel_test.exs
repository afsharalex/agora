defmodule Agora.Agent.ServerCancelTest do
  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig, CancelToken, Error, Message}
  alias Agora.Tool.FunctionTool
  alias Agora.ToolCall

  defp echo_config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [provider: :echo, model: "echo", name: "server_cancel_test"],
        opts
      )
    )
  end

  describe "soft cancel via Agent.run/3" do
    test "cancelled token causes immediate exit at loop boundary" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      result = Agent.run(pid, "Hello", cancel_token: token)
      assert {:error, %Error{type: :cancelled}} = result
    end

    test "cancel during slow tool execution exits at next boundary" do
      token = CancelToken.new()
      test_pid = self()

      tool =
        FunctionTool.new!(
          name: "slow",
          description: "Slow tool",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx ->
            send(test_pid, {:tool_pid, self()})

            receive do
              :continue -> :ok
            end

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
              call = ToolCall.new(%{id: "c1", name: "slow", arguments: %{}})
              {:ok, Message.assistant(nil, [call])}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      task =
        Task.async(fn ->
          Agent.run(pid, "Go", cancel_token: token)
        end)

      # Wait for tool to start, get its pid
      assert_receive {:tool_pid, tool_pid}

      # Cancel while tool is executing — tool will finish, then next iteration check triggers
      CancelToken.cancel(token)
      send(tool_pid, :continue)

      result = Task.await(task, 5000)
      assert {:error, %Error{type: :cancelled}} = result
    end
  end

  describe "hard kill via Agent.run/3" do
    test "kill terminates in-flight reasoning task" do
      token = CancelToken.new()
      test_pid = self()

      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              send(test_pid, :provider_called)

              receive do
                :never -> :ok
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      task =
        Task.async(fn ->
          Agent.run(pid, "Hello", cancel_token: token)
        end)

      assert_receive :provider_called

      # Hard kill should terminate the reasoning task
      CancelToken.kill(token)

      result = Task.await(task, 5000)
      assert {:error, %Error{type: :cancelled}} = result
    end

    test "GenServer returns to :idle after kill and accepts new run" do
      token = CancelToken.new()
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                # First call: block forever (will be killed)
                send(test_pid, :provider_called)

                receive do
                  :never -> :ok
                end
              else
                # Subsequent calls: respond normally
                {:ok, Message.assistant("recovered")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      task =
        Task.async(fn ->
          Agent.run(pid, "Hello", cancel_token: token)
        end)

      assert_receive :provider_called
      CancelToken.kill(token)

      # First run returns cancelled
      assert {:error, %Error{type: :cancelled}} = Task.await(task, 5000)

      # Agent is usable again (without cancel token) — counter is now 2, so responds normally
      assert {:ok, %Message{content: "recovered"}} = Agent.run(pid, "Hello again")
    end
  end

  describe "backward compatibility" do
    test "Agent.run/2 works without opts" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      assert {:ok, %Message{content: content}} = Agent.run(pid, "Hello")
      assert content =~ "Hello"
    end

    test "Agent.run/3 with empty opts works" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      assert {:ok, %Message{}} = Agent.run(pid, "Hello", [])
    end
  end

  describe "queue regression" do
    test "two concurrent run/2 calls queue and both complete" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              Process.sleep(20)
              {:ok, Message.assistant("response")}
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      # Spawn two concurrent callers
      task1 = Task.async(fn -> Agent.run(pid, "First") end)
      task2 = Task.async(fn -> Agent.run(pid, "Second") end)

      # Both should succeed (second queues behind first)
      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)

      assert {:ok, %Message{}} = result1
      assert {:ok, %Message{}} = result2

      # Both messages should be in history
      messages = Agent.get_messages(pid)
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end
  end

  describe "stream_run with cancel" do
    test "stream_run/3 accepts cancel_token option" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      assert {:ok, stream} = Agent.stream_run(pid, "Hello", cancel_token: nil)
      # Consume stream
      events = Enum.to_list(stream)
      assert Enum.any?(events, &(&1.type == :done))
    end
  end

  describe "opts validation" do
    test "invalid cancel_token returns config error on run" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      result = Agent.run(pid, "Hello", cancel_token: :not_a_token)
      assert {:error, %Error{type: :config_error}} = result
    end

    test "invalid cancel_token returns config error on stream_run" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      result = Agent.stream_run(pid, "Hello", cancel_token: "bad")
      assert {:error, %Error{type: :config_error}} = result
    end

    test "agent remains idle after invalid opts" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      # Invalid opts should not change state
      {:error, _} = Agent.run(pid, "Hello", cancel_token: 42)

      # Should still work with valid opts
      assert {:ok, %Message{}} = Agent.run(pid, "Hello")
    end
  end
end
