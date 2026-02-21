defmodule Agora.Telemetry.EventBusBridgeTest do
  use ExUnit.Case, async: true

  alias Agora.Telemetry.EventBusBridge
  alias Agora.ModeEvent

  setup do
    on_exit(fn -> EventBusBridge.detach() end)
  end

  describe "attach/1" do
    test "attaches handler" do
      assert :ok = EventBusBridge.attach()
    end

    test "double attach is idempotent" do
      assert :ok = EventBusBridge.attach()
      assert :ok = EventBusBridge.attach(topic: :custom)
    end
  end

  describe "detach/0" do
    test "detaches handler" do
      EventBusBridge.attach()
      assert :ok = EventBusBridge.detach()
    end

    test "detach when not attached is safe" do
      assert :ok = EventBusBridge.detach()
    end
  end

  describe "event forwarding" do
    test "forwards mode events to EventBus subscribers" do
      EventBusBridge.attach()
      Agora.EventBus.subscribe(:mode_events)

      event = ModeEvent.mode_started(:single, :string, 5)

      :telemetry.execute(
        [:agora, :mode, :event],
        %{system_time: System.system_time()},
        %{event: event}
      )

      assert_receive {Agora.EventBus, :mode_events, ^event}
    end

    test "custom topic" do
      EventBusBridge.attach(topic: :my_events)
      Agora.EventBus.subscribe(:my_events)

      event = ModeEvent.done()

      :telemetry.execute(
        [:agora, :mode, :event],
        %{system_time: System.system_time()},
        %{event: event}
      )

      assert_receive {Agora.EventBus, :my_events, ^event}
    end

    test "detach stops delivery" do
      EventBusBridge.attach()
      Agora.EventBus.subscribe(:mode_events)

      EventBusBridge.detach()

      event = ModeEvent.done()

      :telemetry.execute(
        [:agora, :mode, :event],
        %{system_time: System.system_time()},
        %{event: event}
      )

      refute_receive {Agora.EventBus, :mode_events, _}
    end

    test "re-attach with new topic switches delivery" do
      EventBusBridge.attach(topic: :old_topic)
      Agora.EventBus.subscribe(:old_topic)
      Agora.EventBus.subscribe(:new_topic)

      EventBusBridge.attach(topic: :new_topic)

      event = ModeEvent.done()

      :telemetry.execute(
        [:agora, :mode, :event],
        %{system_time: System.system_time()},
        %{event: event}
      )

      assert_receive {Agora.EventBus, :new_topic, ^event}
      refute_receive {Agora.EventBus, :old_topic, _}
    end
  end
end
