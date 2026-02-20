defmodule Agora.Workflow.CheckpointStore.Memory do
  @moduledoc """
  In-memory map checkpoint backend.

  Stores step results in a plain map. Useful for testing and workflows
  that don't need persistence across process restarts.

  ## Configuration

  No options required. An empty keyword list is accepted.

  ## Example

      checkpoint_store: {Agora.Workflow.CheckpointStore.Memory, []}

  """

  @behaviour Agora.Workflow.CheckpointStore

  @impl true
  def init(_opts) do
    {:ok, %{results: %{}}}
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
end
