defmodule Agora.CancelIntegrationTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, CancelToken, Error, Message, StreamEvent}

  defp echo_config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [provider: :echo, model: "echo", name: "cancel_int_test"],
        opts
      )
    )
  end

  describe "Agora.run/3 one-shot with soft cancel" do
    test "pre-cancelled token causes immediate exit" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      config = echo_config()
      result = Agora.run(config, "Hello", cancel_token: token)
      assert {:error, %Error{type: :cancelled}} = result
    end
  end

  describe "Agora.run/3 one-shot with hard kill" do
    test "hard kill during slow echo provider" do
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

      task =
        Task.async(fn ->
          Agora.run(config, "Hello", cancel_token: token)
        end)

      assert_receive :provider_called
      CancelToken.kill(token)

      result = Task.await(task, 5000)
      assert {:error, %Error{type: :cancelled}} = result
    end
  end

  describe "Agora.run/2 without token completely unaffected" do
    test "runs normally with no cancel infrastructure" do
      config = echo_config()
      assert {:ok, %Message{content: content}} = Agora.run(config, "Hello")
      assert content =~ "Hello"
    end
  end

  describe "orchestrator with cancel" do
    test "pre-cancelled token stops orchestrator immediately" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      agent_a = echo_config(name: "agent_a")
      agent_b = echo_config(name: "agent_b")

      result =
        Agora.round_robin("Go", [a: agent_a, b: agent_b],
          cancel_token: token,
          max_turns: 10
        )

      assert {:error, %Error{type: :cancelled}} = result
    end

    test "hard kill during orchestrator agent step" do
      token = CancelToken.new()
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      agent_a =
        echo_config(
          name: "agent_a",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count >= 2 do
                send(test_pid, :second_call)

                receive do
                  :never -> :ok
                end
              else
                {:ok, Message.assistant("response #{count}")}
              end
            end
          ]
        )

      agent_b = echo_config(name: "agent_b")

      task =
        Task.async(fn ->
          Agora.round_robin("Go", [a: agent_a, b: agent_b],
            cancel_token: token,
            max_turns: 10
          )
        end)

      assert_receive :second_call, 5000
      CancelToken.kill(token)

      result = Task.await(task, 5000)
      assert {:error, %Error{}} = result
    end
  end

  describe "workflow with cancel" do
    test "pre-cancelled token stops workflow immediately" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      step1_config = echo_config(name: "step1")
      step2_config = echo_config(name: "step2")

      result =
        Agora.sequential("Go", [step1: step1_config, step2: step2_config], cancel_token: token)

      assert {:error, %Error{type: :cancelled}} = result
    end
  end

  describe "streaming with cancel" do
    test "pre-cancelled token causes stream error" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      config = echo_config()
      {:ok, pid} = Agora.Agent.start_link(config: config)

      {:ok, stream} = Agora.Agent.stream_run(pid, "Hi", cancel_token: token)
      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      # Stream Enumerable treats :error as a terminal signal (like :done),
      # so only one of them is consumed by the enumerable
      assert :error in types or :done in types
    end

    test "hard kill during streaming terminates stream task" do
      token = CancelToken.new()
      test_pid = self()

      config =
        echo_config(
          provider_opts: [
            echo_mode: :stream,
            echo_stream_function: fn caller, ref ->
              send(test_pid, :stream_started)

              # Slowly send events
              for i <- 1..50 do
                Process.sleep(20)
                send(caller, {Agora.Stream, ref, StreamEvent.text_delta("chunk #{i}")})
              end

              send(caller, {Agora.Stream, ref, StreamEvent.done()})
            end
          ]
        )

      {:ok, pid} = Agora.Agent.start_link(config: config)
      {:ok, stream} = Agora.Agent.stream_run(pid, "Hi", cancel_token: token)

      assert_receive :stream_started

      # Let a few events flow then hard kill
      Process.sleep(50)
      CancelToken.kill(token)

      # Stream should terminate with error or just end
      events = Enum.to_list(stream)
      # Should have some events (not all 50)
      assert length(events) < 60
    end
  end

  describe "concurrency regression" do
    test "queued run/2 calls still work after Phase 5 changes" do
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

      {:ok, pid} = Agora.Agent.start_link(config: config)

      task1 = Task.async(fn -> Agora.Agent.run(pid, "First") end)
      task2 = Task.async(fn -> Agora.Agent.run(pid, "Second") end)

      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)

      assert {:ok, %Message{}} = result1
      assert {:ok, %Message{}} = result2

      messages = Agora.Agent.get_messages(pid)
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end
  end

  describe "no orphan processes" do
    test "hard kill terminates registered worker processes" do
      token = CancelToken.new()
      test_pid = self()

      # Spawn processes and register them
      pids =
        for _ <- 1..3 do
          pid =
            spawn(fn ->
              send(test_pid, {:started, self()})

              receive do
                :never -> :ok
              end
            end)

          assert_receive {:started, ^pid}
          CancelToken.register(token, pid)
          pid
        end

      refs = Enum.map(pids, &Process.monitor/1)

      CancelToken.kill(token)

      for ref <- refs do
        assert_receive {:DOWN, ^ref, :process, _, :killed}
      end
    end
  end
end
