defmodule Agora.ExecutionWorkflowStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, ModeEvent}

  describe "sequential streaming" do
    test "emits step events in order" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a, fn _r -> {:ok, 1} end},
          {:b,
           fn r ->
             {:ok, val} = r[:a]
             {:ok, val + 1}
           end}
        ])

      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      assert :mode_started in types
      assert :step_started in types
      assert :step_completed in types
      assert :mode_completed in types
      assert :done in types

      # Verify step order: a starts/completes before b starts/completes
      step_events =
        Enum.filter(events, &(&1.type in [:step_started, :step_completed]))

      step_ids = Enum.map(step_events, & &1.data.step_id)
      assert step_ids == [:a, :a, :b, :b]
    end

    test "mode field is set to :sequential" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a, fn _r -> {:ok, 1} end}
        ])

      events = Enum.to_list(stream)
      started = Enum.find(events, &(&1.type == :mode_started))
      assert started.mode == :sequential
    end
  end

  describe "parallel streaming" do
    test "emits step events for concurrent branches" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(:parallel, [
          {:analyze, fn _r -> {:ok, :analyzed} end},
          {:summarize, fn _r -> {:ok, :summarized} end}
        ])

      events = Enum.to_list(stream)
      step_completed = Enum.filter(events, &(&1.type == :step_completed))

      # Both steps should complete (order is nondeterministic)
      step_ids = step_completed |> Enum.map(& &1.data.step_id) |> MapSet.new()
      assert MapSet.equal?(step_ids, MapSet.new([:analyze, :summarize]))
    end
  end

  describe "dag streaming" do
    test "emits step events" do
      workflow =
        Agora.Workflow.Builder.new()
        |> Agora.Workflow.Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Agora.Workflow.Builder.step(:b, fn _r -> {:ok, 2} end)
        |> Agora.Workflow.Builder.build!()

      {:ok, stream} = Agora.Execution.run_mode_stream(:dag, workflow)

      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      assert :mode_started in types
      assert :step_started in types
      assert :step_completed in types
      assert :mode_completed in types
      assert :done in types
    end

    test "mode field is set to :dag" do
      workflow =
        Agora.Workflow.Builder.new()
        |> Agora.Workflow.Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Agora.Workflow.Builder.build!()

      {:ok, stream} = Agora.Execution.run_mode_stream(:dag, workflow)

      events = Enum.to_list(stream)
      started = Enum.find(events, &(&1.type == :mode_started))
      assert started.mode == :dag
    end
  end

  describe "conditional streaming" do
    test "emits step events for matching branch" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(
          :conditional,
          {
            {:router, fn _r -> {:ok, :path_a} end},
            [
              {fn r -> r[:router] == {:ok, :path_a} end,
               {:handler_a, fn _r -> {:ok, :handled_a} end}},
              {fn r -> r[:router] == {:ok, :path_b} end,
               {:handler_b, fn _r -> {:ok, :handled_b} end}}
            ]
          }
        )

      events = Enum.to_list(stream)
      types = Enum.map(events, & &1.type)

      assert :mode_started in types
      assert :mode_completed in types
      assert :done in types

      # Router step should have events
      step_started_ids =
        events
        |> Enum.filter(&(&1.type == :step_started))
        |> Enum.map(& &1.data.step_id)

      assert :router in step_started_ids
    end
  end

  describe "error handling" do
    test "workflow failure emits mode_failed" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a, fn _r -> {:error, Error.new(:workflow_error, "boom")} end},
          {:b, fn _r -> {:ok, :never} end}
        ])

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

  describe "on_event callback crash" do
    test "workflow completes even if on_event raises" do
      workflow =
        Agora.Workflow.Builder.new()
        |> Agora.Workflow.Builder.step(:a, fn _r -> {:ok, 42} end)
        |> Agora.Workflow.Builder.build!()

      crashing_callback = fn _event -> raise "boom" end

      {:ok, results} =
        Agora.Workflow.Executor.run(workflow, on_event: crashing_callback)

      assert results[:a] == {:ok, 42}
    end
  end

  describe "all events are ModeEvent structs" do
    test "sequential mode" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a, fn _r -> {:ok, 1} end}
        ])

      events = Enum.to_list(stream)

      for event <- events do
        assert %ModeEvent{} = event
      end
    end

    test "dag mode" do
      workflow =
        Agora.Workflow.Builder.new()
        |> Agora.Workflow.Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Agora.Workflow.Builder.build!()

      {:ok, stream} = Agora.Execution.run_mode_stream(:dag, workflow)
      events = Enum.to_list(stream)

      for event <- events do
        assert %ModeEvent{} = event
      end
    end
  end

  describe "early halt" do
    test "stream can be halted early with Enum.take" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a, fn _r -> {:ok, 1} end},
          {:b, fn _r -> {:ok, 2} end},
          {:c, fn _r -> {:ok, 3} end}
        ])

      # Take only the first 2 events
      events = Enum.take(stream, 2)
      assert length(events) == 2

      for event <- events do
        assert %ModeEvent{} = event
      end
    end

    test "stream task is cleaned up after early halt" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a,
           fn _r ->
             Process.sleep(10)
             {:ok, 1}
           end},
          {:b,
           fn _r ->
             Process.sleep(10)
             {:ok, 2}
           end},
          {:c,
           fn _r ->
             Process.sleep(10)
             {:ok, 3}
           end}
        ])

      _events = Enum.take(stream, 1)

      # Give cleanup a moment to run
      Process.sleep(50)

      # The stream task should have been killed by the after-fun
      # We can't directly inspect the task pid, but we can verify no lingering
      # messages arrive from the stream
      refute_receive {Agora.Stream, _, _}, 100
    end
  end

  describe "telemetry emission" do
    test "workflow streaming emits [:agora, :mode, :event] telemetry" do
      test_ref = make_ref()
      test_pid = self()

      handler_id = "wf-stream-telemetry-#{inspect(test_ref)}"

      :telemetry.attach(
        handler_id,
        [:agora, :mode, :event],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, test_ref, metadata.event})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a, fn _r -> {:ok, 1} end}
        ])

      _events = Enum.to_list(stream)

      # Should receive telemetry for mode_started at minimum
      assert_receive {:telemetry_event, ^test_ref, %ModeEvent{type: :mode_started}}, 1000
      assert_receive {:telemetry_event, ^test_ref, %ModeEvent{type: :done}}, 1000
    end

    test "workflow streaming merges telemetry_metadata into mode events" do
      test_ref = make_ref()
      test_pid = self()

      handler_id = "wf-stream-meta-#{inspect(test_ref)}"

      :telemetry.attach(
        handler_id,
        [:agora, :mode, :event],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:telemetry_meta, test_ref, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, stream} =
        Agora.Execution.run_mode_stream(
          :sequential,
          [
            {:a, fn _r -> {:ok, 1} end}
          ],
          telemetry_metadata: %{custom_key: :test_value}
        )

      _events = Enum.to_list(stream)

      assert_receive {:telemetry_meta, ^test_ref, metadata}, 1000
      assert metadata.custom_key == :test_value
      assert %ModeEvent{} = metadata.event
      # Event struct itself also carries metadata
      assert metadata.event.metadata.custom_key == :test_value
    end

    test "workflow ModeEvent structs carry telemetry_metadata in event.metadata" do
      {:ok, stream} =
        Agora.Execution.run_mode_stream(
          :sequential,
          [
            {:a, fn _r -> {:ok, 1} end}
          ],
          telemetry_metadata: %{trace_id: "abc-123"}
        )

      events = Enum.to_list(stream)

      for event <- events do
        assert %ModeEvent{} = event
        assert event.metadata.trace_id == "abc-123"
      end
    end

    test "EventBusBridge receives workflow stream events" do
      Agora.Telemetry.EventBusBridge.attach(topic: :wf_stream_test)
      on_exit(fn -> Agora.Telemetry.EventBusBridge.detach() end)

      Agora.EventBus.subscribe(:wf_stream_test)

      {:ok, stream} =
        Agora.Execution.run_mode_stream(:sequential, [
          {:a, fn _r -> {:ok, 1} end}
        ])

      _events = Enum.to_list(stream)

      assert_receive {Agora.EventBus, :wf_stream_test, %ModeEvent{type: :mode_started}}
      assert_receive {Agora.EventBus, :wf_stream_test, %ModeEvent{type: :done}}
    end
  end
end
