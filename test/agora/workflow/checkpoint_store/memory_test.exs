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
end
