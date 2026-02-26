defmodule Agora.CancelTokenTest do
  use ExUnit.Case, async: true

  alias Agora.CancelToken

  describe "new/0" do
    test "returns an uncancelled token" do
      token = CancelToken.new()
      assert %CancelToken{ref: ref} = token
      assert is_reference(ref)
      refute CancelToken.cancelled?(token)
      refute CancelToken.killed?(token)
    end
  end

  describe "cancel/1" do
    test "transitions token to cancelled" do
      token = CancelToken.new()
      refute CancelToken.cancelled?(token)

      assert :ok = CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end

    test "is idempotent" do
      token = CancelToken.new()
      assert :ok = CancelToken.cancel(token)
      assert :ok = CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end

    test "does not set kill flag" do
      token = CancelToken.new()
      CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
      refute CancelToken.killed?(token)
    end
  end

  describe "cancelled?/1" do
    test "returns false for new token" do
      refute CancelToken.cancelled?(CancelToken.new())
    end

    test "returns true after cancel" do
      token = CancelToken.new()
      CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end

    test "returns true after kill (kill implies cancel)" do
      token = CancelToken.new()
      CancelToken.kill(token)
      assert CancelToken.cancelled?(token)
    end

    test "visible across processes" do
      token = CancelToken.new()
      parent = self()

      spawn(fn ->
        CancelToken.cancel(token)
        send(parent, :cancelled)
      end)

      assert_receive :cancelled
      assert CancelToken.cancelled?(token)
    end
  end

  describe "kill/1" do
    test "sets both flags" do
      token = CancelToken.new()
      refute CancelToken.cancelled?(token)
      refute CancelToken.killed?(token)

      assert :ok = CancelToken.kill(token)
      assert CancelToken.cancelled?(token)
      assert CancelToken.killed?(token)
    end

    test "is idempotent" do
      token = CancelToken.new()
      assert :ok = CancelToken.kill(token)
      assert :ok = CancelToken.kill(token)
      assert CancelToken.killed?(token)
    end

    test "terminates all registered processes" do
      token = CancelToken.new()
      parent = self()

      pids =
        for _ <- 1..3 do
          spawn(fn ->
            send(parent, {:started, self()})

            receive do
              :never -> :ok
            end
          end)
        end

      # Wait for all to start
      for pid <- pids do
        assert_receive {:started, ^pid}
      end

      # Register all in cancel group
      for pid <- pids do
        CancelToken.register(token, pid)
      end

      # Monitor all
      refs = Enum.map(pids, &Process.monitor/1)

      # Kill
      CancelToken.kill(token)

      # All should die
      for ref <- refs do
        assert_receive {:DOWN, ^ref, :process, _, :killed}
      end
    end

    test "cross-process visibility" do
      token = CancelToken.new()
      parent = self()

      spawn(fn ->
        CancelToken.kill(token)
        send(parent, :killed)
      end)

      assert_receive :killed
      assert CancelToken.killed?(token)
      assert CancelToken.cancelled?(token)
    end
  end

  describe "killed?/1" do
    test "returns false for new token" do
      refute CancelToken.killed?(CancelToken.new())
    end

    test "returns false after cancel (cancel doesn't imply kill)" do
      token = CancelToken.new()
      CancelToken.cancel(token)
      refute CancelToken.killed?(token)
    end

    test "returns true after kill" do
      token = CancelToken.new()
      CancelToken.kill(token)
      assert CancelToken.killed?(token)
    end
  end

  describe "register/2 and unregister/2" do
    test "register adds process to group" do
      token = CancelToken.new()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert :ok = CancelToken.register(token, pid)
      assert :ok = CancelToken.unregister(token, pid)
      send(pid, :stop)
    end

    test "unregister is safe for non-members" do
      token = CancelToken.new()
      assert :ok = CancelToken.unregister(token, self())
    end

    test "late joiner auto-kill: register after kill immediately kills the process" do
      token = CancelToken.new()
      CancelToken.kill(token)

      # Spawn a process AFTER kill
      pid =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      ref = Process.monitor(pid)

      # Register should auto-kill
      CancelToken.register(token, pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end
  end

  describe "backward compatibility" do
    test "new/0 still works for basic usage" do
      token = CancelToken.new()
      refute CancelToken.cancelled?(token)
      CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end

    test "atomics have 2 slots (soft + hard)" do
      token = CancelToken.new()
      # Verify we can read both slots without error
      refute CancelToken.cancelled?(token)
      refute CancelToken.killed?(token)
    end
  end
end
