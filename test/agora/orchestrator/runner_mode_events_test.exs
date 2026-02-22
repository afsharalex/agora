defmodule Agora.Orchestrator.RunnerModeEventsTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Orchestrator}
  alias Agora.Orchestrator.{Runner, TerminationCondition}

  # Each test uses a unique test_id in telemetry_metadata to filter events
  # in async mode, preventing cross-test capture from global telemetry handlers.

  defp echo_config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end

  defp setup_mode_events do
    test_id = make_ref()
    handler_id = "mode-events-#{inspect(test_id)}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [[:agora, :mode, :event]],
      fn _event_name, _measurements, %{event: event} = _metadata, _config ->
        send(test_pid, {:mode_event, event})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    test_id
  end

  defp collect_mode_events(test_id, timeout \\ 100) do
    collect_mode_events_acc(test_id, [], timeout)
  end

  defp collect_mode_events_acc(test_id, acc, timeout) do
    receive do
      {:mode_event, %{metadata: %{test_id: ^test_id}} = event} ->
        collect_mode_events_acc(test_id, [event | acc], timeout)

      {:mode_event, _other} ->
        # Event from a different test, skip it
        collect_mode_events_acc(test_id, acc, timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  describe "single mode events" do
    test "emits full lifecycle: started → selected → step_started → step_completed → completed" do
      test_id = setup_mode_events()

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Orchestrator.Single,
          agents: %{helper: echo_config()},
          telemetry_metadata: %{test_id: test_id}
        )

      {:ok, _msg} = Runner.run(pid, "Hello")
      events = collect_mode_events(test_id)
      types = Enum.map(events, & &1.type)

      assert types == [
               :mode_started,
               :agent_selected,
               :step_started,
               :step_completed,
               :mode_completed
             ]

      # Verify mode_started has redacted input
      started = Enum.find(events, &(&1.type == :mode_started))
      assert started.mode == :single
      assert started.data.input_type == :string
      assert started.data.input_size == 5

      # Verify agent_selected
      selected = Enum.find(events, &(&1.type == :agent_selected))
      assert selected.data.agent == :helper
      assert selected.data.turn == 0

      # Verify step_completed
      completed = Enum.find(events, &(&1.type == :step_completed))
      assert completed.data.result == :ok

      # Verify mode_completed
      mode_done = Enum.find(events, &(&1.type == :mode_completed))
      assert mode_done.data.turns == 1

      GenServer.stop(pid)
    end
  end

  describe "round_robin mode events" do
    test "emits multiple agent_selected events" do
      test_id = setup_mode_events()

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Orchestrator.RoundRobin,
          agents: %{a: echo_config(), b: echo_config()},
          termination: TerminationCondition.max_turns(3),
          telemetry_metadata: %{test_id: test_id}
        )

      {:ok, _msg} = Runner.run(pid, "Hello")
      events = collect_mode_events(test_id)

      selected_events = Enum.filter(events, &(&1.type == :agent_selected))
      assert length(selected_events) == 3

      agents = Enum.map(selected_events, & &1.data.agent)
      assert Enum.at(agents, 0) in [:a, :b]

      GenServer.stop(pid)
    end
  end

  describe "handoff mode events" do
    test "emits handoff event on baton pass" do
      test_id = setup_mode_events()
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
                {:ok, Agora.Message.assistant("HANDOFF:b:please handle this")}
              else
                {:ok, Agora.Message.assistant("Done!")}
              end
            end
          ]
        )

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Orchestrator.Handoff,
          agents: %{a: config, b: config},
          orchestrator_opts: [initial_agent: :a],
          telemetry_metadata: %{test_id: test_id}
        )

      {:ok, _msg} = Runner.run(pid, "Hello")
      events = collect_mode_events(test_id)

      handoff_events = Enum.filter(events, &(&1.type == :handoff))
      assert length(handoff_events) == 1

      handoff = hd(handoff_events)
      assert handoff.data.from == :a
      assert handoff.data.to == :b
      assert handoff.data.message == "please handle this"
      assert handoff.mode == :handoff

      GenServer.stop(pid)
    end
  end

  describe "plan mode events" do
    test "emits replan event when planner replans" do
      test_id = setup_mode_events()
      counter = :counters.new(1, [:atomics])

      planner_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              case count do
                0 ->
                  {:ok, Agora.Message.assistant("PLAN\nSTEP:1:worker:Do the thing\nEND_PLAN")}

                1 ->
                  {:ok, Agora.Message.assistant("Step result")}

                2 ->
                  {:ok, Agora.Message.assistant("REVIEW:REPLAN:unsatisfactory")}

                3 ->
                  {:ok, Agora.Message.assistant("PLAN\nSTEP:1:worker:Do it better\nEND_PLAN")}

                4 ->
                  {:ok, Agora.Message.assistant("Better result")}

                _ ->
                  {:ok, Agora.Message.assistant("REVIEW:COMPLETE:all done")}
              end
            end
          ]
        )

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Orchestrator.Plan,
          agents: %{planner: planner_config, worker: planner_config},
          orchestrator_opts: [planner_agent: :planner],
          telemetry_metadata: %{test_id: test_id}
        )

      {:ok, _msg} = Runner.run(pid, "Do something")
      events = collect_mode_events(test_id)

      replan_events = Enum.filter(events, &(&1.type == :replan))
      assert length(replan_events) == 1

      replan = hd(replan_events)
      assert replan.data.replan_count == 1
      assert replan.data.reason == "unsatisfactory"
      assert replan.mode == :plan

      GenServer.stop(pid)
    end
  end

  describe "cancellation events" do
    test "emits mode_cancelled when cancel token fires" do
      test_id = setup_mode_events()
      token = Agora.CancelToken.new()
      Agora.CancelToken.cancel(token)

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Orchestrator.Single,
          agents: %{helper: echo_config()},
          cancel_token: token,
          telemetry_metadata: %{test_id: test_id}
        )

      {:error, %Error{type: :cancelled}} = Runner.run(pid, "Hello")
      events = collect_mode_events(test_id)

      cancelled = Enum.filter(events, &(&1.type == :mode_cancelled))
      assert length(cancelled) == 1

      event = hd(cancelled)
      assert event.data.boundary == :before_step

      GenServer.stop(pid)
    end
  end

  describe "error events" do
    test "emits mode_failed on orchestration error" do
      test_id = setup_mode_events()

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

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Orchestrator.Single,
          agents: %{helper: config},
          telemetry_metadata: %{test_id: test_id}
        )

      {:error, _} = Runner.run(pid, "Hello")
      events = collect_mode_events(test_id)

      failed = Enum.filter(events, &(&1.type == :mode_failed))
      assert length(failed) == 1

      event = hd(failed)
      assert %Error{} = event.data.error
      assert event.mode == :single

      GenServer.stop(pid)
    end
  end

  describe "Runner.stream_run/2" do
    test "stream task crash produces ModeEvent.error and runner recovers" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              Process.sleep(500)
              {:ok, Agora.Message.assistant("Response")}
            end
          ]
        )

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Orchestrator.Single,
          agents: %{agent: config}
        )

      {:ok, stream} = Runner.stream_run(runner, "Hello")

      # Kill the streaming task
      Process.exit(stream.pid, :kill)

      events = Enum.to_list(stream)

      # Should contain a ModeEvent.error (not StreamEvent.error)
      assert Enum.any?(events, fn event ->
               match?(%Agora.ModeEvent{type: :error}, event)
             end)

      # Runner should recover to idle
      Process.sleep(100)
      assert Runner.get_status(runner) == :idle

      GenServer.stop(runner)
    end

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
              {:ok, Agora.Message.assistant("Response")}
            end
          ]
        )

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Orchestrator.Single,
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
              {:ok, Agora.Message.assistant("Response")}
            end
          ]
        )

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Orchestrator.Single,
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

  describe "telemetry_metadata propagation" do
    test "custom metadata appears in mode events" do
      test_id = setup_mode_events()

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Orchestrator.Single,
          agents: %{helper: echo_config()},
          telemetry_metadata: %{test_id: test_id, custom_key: "custom_value"}
        )

      {:ok, _msg} = Runner.run(pid, "Hello")
      events = collect_mode_events(test_id)

      assert length(events) > 0

      for event <- events do
        assert event.metadata.custom_key == "custom_value"
      end

      GenServer.stop(pid)
    end
  end
end
