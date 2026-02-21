defmodule Agora.ExecutionStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, CancelToken, ContextPolicy, Error, Message, ModeEvent}
  alias Agora.Orchestrator.{Runner, TerminationCondition}

  defp echo_config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end

  describe "single mode streaming" do
    test "collects full lifecycle events" do
      {:ok, stream} =
        Agora.run_mode_stream(:single, "Hello",
          agents: %{helper: echo_config()}
        )

      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      assert types == [
               :mode_started,
               :agent_selected,
               :step_started,
               :step_completed,
               :mode_completed,
               :done
             ]

      # Verify mode_started has redacted input
      started = Enum.find(events, &(&1.type == :mode_started))
      assert started.mode == :single
      assert started.data.input_type == :string
      assert started.data.input_size == 5

      # Verify done event
      done = List.last(events)
      assert %ModeEvent{type: :done} = done
    end

    test "events are all ModeEvent structs" do
      {:ok, stream} =
        Agora.run_mode_stream(:single, "Hello",
          agents: %{helper: echo_config()}
        )

      events = Enum.to_list(stream)

      for event <- events do
        assert %ModeEvent{} = event
      end
    end
  end

  describe "round_robin mode streaming" do
    test "emits multiple step cycles" do
      {:ok, stream} =
        Agora.run_mode_stream(:round_robin, "Hello",
          agents: %{a: echo_config(), b: echo_config()},
          termination: TerminationCondition.max_turns(3)
        )

      events = Enum.to_list(stream)
      step_completed = Enum.filter(events, &(&1.type == :step_completed))
      assert length(step_completed) == 3

      selected = Enum.filter(events, &(&1.type == :agent_selected))
      assert length(selected) == 3
    end
  end

  describe "handoff mode streaming" do
    test "emits handoff event on baton pass" do
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count == 0 do
                {:ok, Message.assistant("HANDOFF:b:please handle this")}
              else
                {:ok, Message.assistant("Done!")}
              end
            end
          ]
        )

      {:ok, stream} =
        Agora.run_mode_stream(:handoff, "Hello",
          agents: %{a: config, b: config},
          orchestrator_opts: [initial_agent: :a]
        )

      events = Enum.to_list(stream)
      handoff_events = Enum.filter(events, &(&1.type == :handoff))
      assert length(handoff_events) == 1

      handoff = hd(handoff_events)
      assert handoff.data.from == :a
      assert handoff.data.to == :b
      assert handoff.data.message == "please handle this"
    end
  end

  describe "cancellation during streaming" do
    test "emits mode_cancelled and done" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      {:ok, stream} =
        Agora.run_mode_stream(:single, "Hello",
          agents: %{helper: echo_config()},
          cancel_token: token
        )

      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      assert :mode_started in types
      assert :mode_cancelled in types
      assert :done in types
      refute :mode_completed in types
    end
  end

  describe "error during streaming" do
    test "emits mode_failed and done" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              {:error, Error.new(:provider_error, "LLM error")}
            end
          ]
        )

      {:ok, stream} =
        Agora.run_mode_stream(:single, "Hello",
          agents: %{helper: config}
        )

      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      assert :mode_started in types
      assert :mode_failed in types
      assert :done in types
      refute :mode_completed in types

      failed = Enum.find(events, &(&1.type == :mode_failed))
      assert %Error{} = failed.data.error
    end
  end

  describe "stream task crash" do
    test "produces ModeEvent.error on task kill" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              Process.sleep(500)
              {:ok, Message.assistant("Response")}
            end
          ]
        )

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: config}
        )

      {:ok, stream} = Runner.stream_run(runner, "Hello")

      # Kill the streaming task
      Process.exit(stream.pid, :kill)

      events = Enum.to_list(stream)

      # Should contain a ModeEvent.error (not StreamEvent.error)
      assert Enum.any?(events, fn event ->
               match?(%ModeEvent{type: :error}, event)
             end)

      # Runner should recover to idle
      Process.sleep(100)
      assert Runner.get_status(runner) == :idle

      GenServer.stop(runner)
    end
  end

  describe "stream ownership enforcement" do
    test "raises when enumerated from wrong process" do
      {:ok, stream} =
        Agora.run_mode_stream(:single, "Hello",
          agents: %{helper: echo_config()}
        )

      task =
        Task.async(fn ->
          try do
            Enum.to_list(stream)
          rescue
            e in ArgumentError -> {:error, e.message}
          end
        end)

      assert {:error, msg} = Task.await(task)
      assert msg =~ "owner process"
    end
  end

  describe "runner concurrency" do
    test "run while streaming returns busy error" do
      test_pid = self()

      slow_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              send(test_pid, :agent_running)
              Process.sleep(300)
              {:ok, Message.assistant("Response")}
            end
          ]
        )

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: slow_config}
        )

      {:ok, _stream} = Runner.stream_run(runner, "Hello")
      assert_receive :agent_running, 5000

      # Runner is busy streaming
      assert {:error, %Error{type: :config_error}} = Runner.run(runner, "World")

      # Also reject another stream_run
      assert {:error, %Error{type: :config_error}} = Runner.stream_run(runner, "World")

      # Wait for streaming to complete and clean up
      Process.sleep(500)
      GenServer.stop(runner)
    end

    test "stream_run while streaming returns busy error" do
      test_pid = self()

      slow_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              send(test_pid, :agent_running)
              Process.sleep(300)
              {:ok, Message.assistant("Response")}
            end
          ]
        )

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: slow_config}
        )

      {:ok, _stream} = Runner.stream_run(runner, "Hello")
      assert_receive :agent_running, 5000

      # Runner is busy streaming — reject another stream_run
      assert {:error, %Error{type: :config_error}} = Runner.stream_run(runner, "World")

      # Wait for streaming to complete and clean up
      Process.sleep(500)
      GenServer.stop(runner)
    end
  end

  describe "context compaction telemetry" do
    test "emits context_compacted event when messages are reduced" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "compaction-test-#{inspect(ref)}",
        [:agora, :mode, :context_compacted],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:compacted, metadata})
        end,
        nil
      )

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)

      # Use a multi-turn orchestrator to accumulate messages beyond the window
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)
              {:ok, Message.assistant("Response #{count}")}
            end
          ]
        )

      {:ok, _result} =
        Agora.run_mode(:round_robin, "Hello",
          agents: %{a: config, b: config},
          termination: TerminationCondition.max_turns(4),
          context_policy: policy
        )

      # Should have received at least one compaction event
      assert_receive {:compacted, metadata}, 1000
      assert metadata.strategy == :sliding_window
      assert metadata.before > metadata.after

      :telemetry.detach("compaction-test-#{inspect(ref)}")
    end

    test "context_compacted event includes telemetry_metadata" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "compaction-meta-test-#{inspect(ref)}",
        [:agora, :mode, :context_compacted],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:compacted_meta, metadata})
        end,
        nil
      )

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)
              {:ok, Message.assistant("Response #{count}")}
            end
          ]
        )

      {:ok, _result} =
        Agora.run_mode(:round_robin, "Hello",
          agents: %{a: config, b: config},
          termination: TerminationCondition.max_turns(4),
          context_policy: policy,
          telemetry_metadata: %{run_id: "test-123"}
        )

      assert_receive {:compacted_meta, metadata}, 1000
      assert metadata.strategy == :sliding_window
      assert metadata.before > metadata.after
      assert metadata.run_id == "test-123"

      :telemetry.detach("compaction-meta-test-#{inspect(ref)}")
    end
  end

  describe "early halt" do
    test "stream can be halted early with Enum.take" do
      {:ok, stream} =
        Agora.run_mode_stream(:round_robin, "Hello",
          agents: %{a: echo_config(), b: echo_config()},
          termination: TerminationCondition.max_turns(10)
        )

      # Take only the first 3 events
      events = Enum.take(stream, 3)
      assert length(events) == 3

      # All events should be ModeEvent structs
      for event <- events do
        assert %ModeEvent{} = event
      end
    end
  end

  describe "validation errors" do
    test "unknown mode returns error" do
      result = Agora.run_mode_stream(:unknown, "Hello", agents: %{a: echo_config()})
      assert {:error, %Error{type: :config_error}} = result
    end

    test "missing agents returns error" do
      result = Agora.run_mode_stream(:single, "Hello", [])
      assert {:error, %Error{type: :config_error}} = result
    end
  end
end
