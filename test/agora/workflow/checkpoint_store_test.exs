defmodule Agora.Workflow.CheckpointStoreTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.CheckpointStore
  alias Agora.Error

  defmodule GoodBackend do
    @behaviour Agora.Workflow.CheckpointStore

    @impl true
    def init(_opts), do: {:ok, %{}}
    @impl true
    def save(state, step_id, result), do: {:ok, Map.put(state, step_id, result)}
    @impl true
    def load(state, step_id), do: {:ok, Map.get(state, step_id)}
    @impl true
    def load_all(state), do: {:ok, state}
    @impl true
    def clear(_state), do: {:ok, %{}}
  end

  defmodule RaisingBackend do
    @behaviour Agora.Workflow.CheckpointStore

    @impl true
    def init(_opts), do: raise("boom")
    @impl true
    def save(_state, _step_id, _result), do: raise("boom")
    @impl true
    def load(_state, _step_id), do: raise("boom")
    @impl true
    def load_all(_state), do: raise("boom")
    @impl true
    def clear(_state), do: raise("boom")
  end

  defmodule ThrowingBackend do
    @behaviour Agora.Workflow.CheckpointStore

    @impl true
    def init(_opts), do: throw(:thrown_value)
    @impl true
    def save(_state, _id, _r), do: throw(:thrown_value)
    @impl true
    def load(_state, _id), do: throw(:thrown_value)
    @impl true
    def load_all(_state), do: throw(:thrown_value)
    @impl true
    def clear(_state), do: throw(:thrown_value)
  end

  defmodule BadReturnBackend do
    @behaviour Agora.Workflow.CheckpointStore

    @impl true
    def init(_opts), do: :bad_return
    @impl true
    def save(_state, _id, _r), do: :bad_return
    @impl true
    def load(_state, _id), do: :bad_return
    @impl true
    def load_all(_state), do: :bad_return
    @impl true
    def clear(_state), do: :bad_return
  end

  describe "init/1" do
    test "initializes valid backend" do
      assert {:ok, {GoodBackend, %{}}} = CheckpointStore.init({GoodBackend, []})
    end

    test "returns error for non-existent module" do
      assert {:error, %Error{type: :workflow_error}} =
               CheckpointStore.init({NonExistentModule, []})
    end

    test "returns error for module without callbacks" do
      assert {:error, %Error{type: :workflow_error}} =
               CheckpointStore.init({String, []})
    end

    test "wraps backend raise in safe_call" do
      assert {:error, %Error{type: :workflow_error, message: msg}} =
               CheckpointStore.init({RaisingBackend, []})

      assert msg =~ "raised"
    end

    test "wraps backend throw in safe_call" do
      assert {:error, %Error{type: :workflow_error, message: msg}} =
               CheckpointStore.init({ThrowingBackend, []})

      assert msg =~ "throw"
    end

    test "wraps unexpected return in safe_call" do
      assert {:error, %Error{type: :workflow_error, message: msg}} =
               CheckpointStore.init({BadReturnBackend, []})

      assert msg =~ "unexpected"
    end
  end

  describe "save/3" do
    test "saves and updates state" do
      {:ok, store} = CheckpointStore.init({GoodBackend, []})
      assert {:ok, {GoodBackend, new_state}} = CheckpointStore.save(store, :step_a, {:ok, 42})
      assert new_state[:step_a] == {:ok, 42}
    end
  end

  describe "load/2" do
    test "loads saved result" do
      {:ok, store} = CheckpointStore.init({GoodBackend, []})
      {:ok, store} = CheckpointStore.save(store, :step_a, {:ok, 42})
      assert {:ok, {:ok, 42}} = CheckpointStore.load(store, :step_a)
    end

    test "returns nil for missing step" do
      {:ok, store} = CheckpointStore.init({GoodBackend, []})
      assert {:ok, nil} = CheckpointStore.load(store, :missing)
    end
  end

  describe "load_all/2" do
    test "loads all results with atom keys" do
      {:ok, store} = CheckpointStore.init({GoodBackend, []})
      {:ok, store} = CheckpointStore.save(store, :a, {:ok, 1})
      {:ok, store} = CheckpointStore.save(store, :b, {:ok, 2})

      assert {:ok, results} = CheckpointStore.load_all(store, [:a, :b])
      assert results == %{a: {:ok, 1}, b: {:ok, 2}}
    end

    test "filters unknown keys" do
      {:ok, store} = CheckpointStore.init({GoodBackend, []})
      {:ok, store} = CheckpointStore.save(store, :a, {:ok, 1})
      {:ok, store} = CheckpointStore.save(store, :stale, {:ok, "old"})

      # Only :a is known
      assert {:ok, results} = CheckpointStore.load_all(store, [:a])
      assert results == %{a: {:ok, 1}}
      refute Map.has_key?(results, :stale)
    end
  end

  describe "clear/1" do
    test "clears all results" do
      {:ok, store} = CheckpointStore.init({GoodBackend, []})
      {:ok, store} = CheckpointStore.save(store, :a, {:ok, 1})
      {:ok, store} = CheckpointStore.clear(store)
      assert {:ok, %{}} = CheckpointStore.load_all(store, [:a])
    end
  end
end
