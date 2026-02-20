defmodule Agora.EventBusTest do
  use ExUnit.Case, async: true

  alias Agora.EventBus

  describe "subscribe/2 and broadcast/2" do
    test "delivers message to subscriber" do
      EventBus.subscribe(:test_topic)
      EventBus.broadcast(:test_topic, :hello)

      assert_receive {Agora.EventBus, :test_topic, :hello}
    end

    test "multiple subscribers receive same broadcast" do
      test_pid = self()

      pids =
        for _ <- 1..3 do
          spawn_link(fn ->
            EventBus.subscribe(:multi_topic)
            send(test_pid, :subscribed)

            receive do
              msg -> send(test_pid, {:got, self(), msg})
            end
          end)
        end

      for _ <- pids, do: assert_receive(:subscribed)

      EventBus.broadcast(:multi_topic, :multi_msg)

      for pid <- pids do
        assert_receive {:got, ^pid, {Agora.EventBus, :multi_topic, :multi_msg}}
      end
    end

    test "broadcast to empty topic returns :ok" do
      assert EventBus.broadcast(:nobody_listening, :msg) == :ok
    end

    test "messages arrive as {Agora.EventBus, topic, message} tuples" do
      EventBus.subscribe(:tuple_topic)
      EventBus.broadcast(:tuple_topic, %{data: 42})

      assert_receive {Agora.EventBus, :tuple_topic, %{data: 42}}
    end
  end

  describe "unsubscribe/1" do
    test "stops delivery after unsubscribe" do
      EventBus.subscribe(:unsub_topic)
      EventBus.broadcast(:unsub_topic, :before)
      assert_receive {Agora.EventBus, :unsub_topic, :before}

      EventBus.unsubscribe(:unsub_topic)
      EventBus.broadcast(:unsub_topic, :after)
      refute_receive {Agora.EventBus, :unsub_topic, :after}
    end
  end

  describe "topic isolation" do
    test "subscriber receives only subscribed topics" do
      EventBus.subscribe(:topic_a)

      EventBus.broadcast(:topic_a, :msg_a)
      EventBus.broadcast(:topic_b, :msg_b)

      assert_receive {Agora.EventBus, :topic_a, :msg_a}
      refute_receive {Agora.EventBus, :topic_b, :msg_b}
    end
  end

  describe "idempotent subscribe" do
    test "second subscribe returns :ok and does not cause duplicate delivery" do
      assert EventBus.subscribe(:idem_topic) == :ok
      assert EventBus.subscribe(:idem_topic) == :ok

      EventBus.broadcast(:idem_topic, :single)

      assert_receive {Agora.EventBus, :idem_topic, :single}
      refute_receive {Agora.EventBus, :idem_topic, :single}
    end
  end

  describe "process exit auto-unregisters" do
    test "dead process does not receive messages" do
      test_pid = self()

      pid =
        spawn(fn ->
          EventBus.subscribe(:exit_topic)
          send(test_pid, :subscribed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # Allow Registry to clean up after process death
      Process.sleep(50)

      EventBus.broadcast(:exit_topic, :after_death)
      refute_receive {Agora.EventBus, :exit_topic, :after_death}
    end
  end
end
