defmodule Agora.ExecutionWorkflowStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, ModeEvent}

  describe "sequential streaming" do
    test "emits step events in order" do
      {:ok, stream} =
        Agora.run_mode_stream(:sequential, [
          {:a, fn _r -> {:ok, 1} end},
          {:b, fn r ->
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
        Agora.run_mode_stream(:sequential, [
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
        Agora.run_mode_stream(:parallel, [
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

      {:ok, stream} = Agora.run_mode_stream(:dag, workflow)

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

      {:ok, stream} = Agora.run_mode_stream(:dag, workflow)

      events = Enum.to_list(stream)
      started = Enum.find(events, &(&1.type == :mode_started))
      assert started.mode == :dag
    end
  end

  describe "conditional streaming" do
    test "emits step events for matching branch" do
      {:ok, stream} =
        Agora.run_mode_stream(
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
        Agora.run_mode_stream(:sequential, [
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
        Agora.run_mode_stream(:sequential, [
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

      {:ok, stream} = Agora.run_mode_stream(:dag, workflow)
      events = Enum.to_list(stream)

      for event <- events do
        assert %ModeEvent{} = event
      end
    end
  end

  describe "early halt" do
    test "stream can be halted early with Enum.take" do
      {:ok, stream} =
        Agora.run_mode_stream(:sequential, [
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
  end
end
