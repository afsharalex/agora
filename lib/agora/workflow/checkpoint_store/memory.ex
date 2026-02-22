defmodule Agora.Workflow.CheckpointStore.Memory do
  @moduledoc """
  In-memory map checkpoint backend with snapshot support.

  Stores step results in a plain map and supports append-only checkpoint
  snapshots with advisory locking. Useful for testing and workflows
  that don't need persistence across process restarts.

  ## Configuration

  No options required. An empty keyword list is accepted.

  ## Example

      checkpoint_store: {Agora.Workflow.CheckpointStore.Memory, []}

  """

  @behaviour Agora.Workflow.CheckpointStore

  alias Agora.Error

  # snapshots: %{checkpoint_id => [%Checkpoint{version: 3}, %Checkpoint{version: 2}, ...]}
  # Newest first for efficient :latest lookup

  @impl true
  def init(_opts) do
    {:ok, %{results: %{}, snapshots: %{}, locks: MapSet.new()}}
  end

  @impl true
  def save(%{results: results} = state, step_id, result) do
    {:ok, %{state | results: Map.put(results, step_id, result)}}
  end

  @impl true
  def load(%{results: results}, step_id) do
    {:ok, Map.get(results, step_id)}
  end

  @impl true
  def load_all(%{results: results}) do
    {:ok, results}
  end

  @impl true
  def clear(state) do
    {:ok, %{state | results: %{}}}
  end

  # --- Optional snapshot callbacks ---

  @impl true
  def save_snapshot(state, %{id: id} = checkpoint) do
    existing = Map.get(state.snapshots, id, [])
    updated = [checkpoint | existing]
    {:ok, %{state | snapshots: Map.put(state.snapshots, id, updated)}}
  end

  @impl true
  def load_snapshot(state, checkpoint_id, :latest) do
    case Map.get(state.snapshots, checkpoint_id, []) do
      [latest | _] -> {:ok, latest}
      [] -> {:ok, nil}
    end
  end

  def load_snapshot(state, checkpoint_id, version) when is_integer(version) do
    snapshots = Map.get(state.snapshots, checkpoint_id, [])
    {:ok, Enum.find(snapshots, fn s -> s.version == version end)}
  end

  @impl true
  def list_snapshots(state) do
    all =
      state.snapshots
      |> Enum.flat_map(fn {_id, versions} ->
        case versions do
          [latest | _] -> [latest]
          [] -> []
        end
      end)

    {:ok, all}
  end

  @impl true
  def delete_snapshot(state, checkpoint_id, version) do
    snapshots = Map.get(state.snapshots, checkpoint_id, [])
    filtered = Enum.reject(snapshots, fn s -> s.version == version end)

    updated_snapshots =
      if filtered == [] do
        Map.delete(state.snapshots, checkpoint_id)
      else
        Map.put(state.snapshots, checkpoint_id, filtered)
      end

    {:ok, %{state | snapshots: updated_snapshots}}
  end

  @impl true
  def lock(state, checkpoint_id) do
    if MapSet.member?(state.locks, checkpoint_id) do
      Error.wrap(:workflow_error, "Checkpoint #{checkpoint_id} is locked")
    else
      {:ok, %{state | locks: MapSet.put(state.locks, checkpoint_id)}}
    end
  end

  @impl true
  def unlock(state, checkpoint_id) do
    {:ok, %{state | locks: MapSet.delete(state.locks, checkpoint_id)}}
  end
end
