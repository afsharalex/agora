defmodule Agora.ModeEventTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, ModeEvent}

  describe "mode_started/4" do
    test "creates event with redacted input metadata" do
      event = ModeEvent.mode_started(:single, :string, 42)
      assert event.type == :mode_started
      assert event.mode == :single
      assert event.data == %{input_type: :string, input_size: 42}
      assert is_integer(event.timestamp)
      assert event.metadata == %{}
    end

    test "accepts custom metadata" do
      event = ModeEvent.mode_started(:handoff, :message, 10, %{custom: true})
      assert event.metadata == %{custom: true}
    end
  end

  describe "agent_selected/4" do
    test "creates event with agent and turn" do
      event = ModeEvent.agent_selected(:round_robin, :helper, 3)
      assert event.type == :agent_selected
      assert event.mode == :round_robin
      assert event.data == %{agent: :helper, turn: 3}
    end
  end

  describe "step_started/4" do
    test "creates orchestrator step event" do
      event = ModeEvent.step_started(:single, :worker, 0)
      assert event.type == :step_started
      assert event.data == %{agent: :worker, turn: 0}
    end
  end

  describe "step_completed/5" do
    test "creates orchestrator step completed event" do
      event = ModeEvent.step_completed(:single, :worker, 0, :ok)
      assert event.type == :step_completed
      assert event.data == %{agent: :worker, turn: 0, result: :ok}
    end

    test "creates error step completed event" do
      event = ModeEvent.step_completed(:single, :worker, 1, :error)
      assert event.data.result == :error
    end
  end

  describe "handoff/5" do
    test "creates handoff event" do
      event = ModeEvent.handoff(:handoff, :agent_a, :agent_b, "context msg")
      assert event.type == :handoff
      assert event.data == %{from: :agent_a, to: :agent_b, message: "context msg"}
    end
  end

  describe "replan/4" do
    test "creates replan event" do
      event = ModeEvent.replan(:plan, 1, "results unsatisfactory")
      assert event.type == :replan
      assert event.data == %{replan_count: 1, reason: "results unsatisfactory"}
    end
  end

  describe "mode_completed/3" do
    test "creates mode completed event" do
      event = ModeEvent.mode_completed(:single, 5)
      assert event.type == :mode_completed
      assert event.data == %{turns: 5}
    end
  end

  describe "mode_failed/4" do
    test "creates mode failed event" do
      error = Error.new(:orchestration_error, "something went wrong")
      event = ModeEvent.mode_failed(:round_robin, error, 3)
      assert event.type == :mode_failed
      assert event.data == %{error: error, turns: 3}
    end
  end

  describe "mode_cancelled/4" do
    test "creates mode cancelled event" do
      event = ModeEvent.mode_cancelled(:single, :before_step, 2)
      assert event.type == :mode_cancelled
      assert event.data == %{boundary: :before_step, turn: 2}
    end
  end

  describe "done/1" do
    test "creates terminal done event" do
      event = ModeEvent.done()
      assert event.type == :done
      assert event.data == %{}
      assert event.mode == nil
    end
  end

  describe "error/2" do
    test "creates terminal error event" do
      error = Error.new(:streaming_error, "process crashed")
      event = ModeEvent.error(error)
      assert event.type == :error
      assert event.data == error
    end
  end

  describe "JSON encoding" do
    test "all event types are Jason-encodable" do
      error = Error.new(:orchestration_error, "test")

      events = [
        ModeEvent.mode_started(:single, :string, 5),
        ModeEvent.agent_selected(:single, :worker, 0),
        ModeEvent.step_started(:single, :worker, 0),
        ModeEvent.step_completed(:single, :worker, 0, :ok),
        ModeEvent.handoff(:handoff, :a, :b, "msg"),
        ModeEvent.replan(:plan, 1, "reason"),
        ModeEvent.mode_completed(:single, 1),
        ModeEvent.mode_failed(:single, error, 1),
        ModeEvent.mode_cancelled(:single, :before_step, 0),
        ModeEvent.done(),
        ModeEvent.error(error)
      ]

      for event <- events do
        assert {:ok, json} = Jason.encode(event)
        assert is_binary(json)
      end
    end
  end
end
