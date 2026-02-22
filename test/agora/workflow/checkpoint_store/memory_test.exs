defmodule Agora.Workflow.CheckpointStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.CheckpointStore.Memory

  describe "init/1" do
    test "initializes with empty results" do
      assert {:ok, state} = Memory.init([])
      assert state.results == %{}
    end
  end

  describe "save/3 and load/2" do
    test "round-trip save and load" do
      {:ok, state} = Memory.init([])
      {:ok, state} = Memory.save(state, :step_a, {:ok, 42})
      assert {:ok, {:ok, 42}} = Memory.load(state, :step_a)
    end

    test "overwrites previous value" do
      {:ok, state} = Memory.init([])
      {:ok, state} = Memory.save(state, :step_a, {:ok, 1})
      {:ok, state} = Memory.save(state, :step_a, {:ok, 2})
      assert {:ok, {:ok, 2}} = Memory.load(state, :step_a)
    end
  end

  describe "load/2" do
    test "returns nil for missing step" do
      {:ok, state} = Memory.init([])
      assert {:ok, nil} = Memory.load(state, :nonexistent)
    end
  end

  describe "load_all/1" do
    test "returns all saved results" do
      {:ok, state} = Memory.init([])
      {:ok, state} = Memory.save(state, :a, {:ok, 1})
      {:ok, state} = Memory.save(state, :b, {:ok, 2})

      assert {:ok, results} = Memory.load_all(state)
      assert results == %{a: {:ok, 1}, b: {:ok, 2}}
    end

    test "returns empty map when nothing saved" do
      {:ok, state} = Memory.init([])
      assert {:ok, %{}} = Memory.load_all(state)
    end
  end

  describe "clear/1" do
    test "removes all saved results" do
      {:ok, state} = Memory.init([])
      {:ok, state} = Memory.save(state, :a, {:ok, 1})
      {:ok, state} = Memory.clear(state)

      assert {:ok, %{}} = Memory.load_all(state)
      assert {:ok, nil} = Memory.load(state, :a)
    end
  end

  describe "save_snapshot/2 and load_snapshot/3" do
    test "save and load latest snapshot" do
      {:ok, state} = Memory.init([])
      checkpoint = build_checkpoint("chk_1")

      {:ok, state} = Memory.save_snapshot(state, checkpoint)
      assert {:ok, loaded} = Memory.load_snapshot(state, "chk_1", :latest)
      assert loaded.id == "chk_1"
    end

    test "load specific version" do
      {:ok, state} = Memory.init([])
      c1 = build_checkpoint("chk_ver", version: 1)
      c2 = build_checkpoint("chk_ver", version: 2, status: :completed)

      {:ok, state} = Memory.save_snapshot(state, c1)
      {:ok, state} = Memory.save_snapshot(state, c2)

      assert {:ok, v1} = Memory.load_snapshot(state, "chk_ver", 1)
      assert v1.version == 1

      assert {:ok, v2} = Memory.load_snapshot(state, "chk_ver", 2)
      assert v2.version == 2
      assert v2.status == :completed
    end

    test "latest returns highest version" do
      {:ok, state} = Memory.init([])

      state =
        Enum.reduce(1..3, state, fn v, acc ->
          c = build_checkpoint("chk_lat", version: v)
          {:ok, new_state} = Memory.save_snapshot(acc, c)
          new_state
        end)

      {:ok, latest} = Memory.load_snapshot(state, "chk_lat", :latest)
      assert latest.version == 3
    end

    test "returns nil for nonexistent checkpoint" do
      {:ok, state} = Memory.init([])
      assert {:ok, nil} = Memory.load_snapshot(state, "nonexistent", :latest)
    end
  end

  describe "list_snapshots/1" do
    test "returns latest version per checkpoint" do
      {:ok, state} = Memory.init([])
      c1 = build_checkpoint("chk_a")
      c2 = build_checkpoint("chk_b")

      {:ok, state} = Memory.save_snapshot(state, c1)
      {:ok, state} = Memory.save_snapshot(state, c2)

      assert {:ok, list} = Memory.list_snapshots(state)
      ids = Enum.map(list, & &1.id) |> Enum.sort()
      assert ids == ["chk_a", "chk_b"]
    end
  end

  describe "delete_snapshot/3" do
    test "removes specific version" do
      {:ok, state} = Memory.init([])
      c1 = build_checkpoint("chk_del", version: 1)
      c2 = build_checkpoint("chk_del", version: 2)

      {:ok, state} = Memory.save_snapshot(state, c1)
      {:ok, state} = Memory.save_snapshot(state, c2)

      {:ok, state} = Memory.delete_snapshot(state, "chk_del", 1)

      assert {:ok, nil} = Memory.load_snapshot(state, "chk_del", 1)
      assert {:ok, v2} = Memory.load_snapshot(state, "chk_del", 2)
      assert v2.version == 2
    end
  end

  describe "lock/2 and unlock/2" do
    test "acquire and release lock" do
      {:ok, state} = Memory.init([])
      {:ok, state} = Memory.lock(state, "chk_lock")
      {:ok, _state} = Memory.unlock(state, "chk_lock")
    end

    test "lock contention returns error" do
      {:ok, state} = Memory.init([])
      {:ok, state} = Memory.lock(state, "chk_lock")
      assert {:error, error} = Memory.lock(state, "chk_lock")
      assert error.message =~ "is locked"
    end

    test "unlock nonexistent is no-op" do
      {:ok, state} = Memory.init([])
      assert {:ok, _state} = Memory.unlock(state, "nonexistent")
    end
  end

  defp build_checkpoint(id, opts \\ []) do
    %Agora.Workflow.Checkpoint{
      id: id,
      workflow_hash: "test_hash",
      version: Keyword.get(opts, :version, 1),
      status: Keyword.get(opts, :status, :in_progress),
      results: %{},
      completed_steps: MapSet.new(),
      pending_steps: MapSet.new(),
      failed_steps: MapSet.new(),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      otp_major_version: 27,
      metadata: %{}
    }
  end
end
