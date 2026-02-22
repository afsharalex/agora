defmodule Agora.Workflow.HandlerRegistry.Default do
  @moduledoc """
  ETS-backed default handler registry.

  Runs as a GenServer that owns a named ETS table. The table uses
  `read_concurrency: true` since reads (resolve) dominate writes (register).

  Added to the application supervision tree. The `state` parameter in
  behaviour callbacks is ignored — all operations target the named ETS table.

  ## Examples

      alias Agora.Workflow.HandlerRegistry.Default

      # Register a handler
      {:ok, _} = Default.register(:default, "fetch", &MyApp.fetch/1)

      # Use with Serializer
      {:ok, map} = Serializer.to_map(workflow,
        handler_registry: {Default, :default}
      )

      # Resolve during reconstruction
      {:ok, workflow} = WorkflowTopology.to_workflow(topology,
        handler_registry: {Default, :default}
      )

  """

  use GenServer

  @behaviour Agora.Workflow.HandlerRegistry

  alias Agora.Error

  # --- GenServer ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # --- HandlerRegistry callbacks ---
  # State is ignored; all operations use the named ETS table.

  @impl Agora.Workflow.HandlerRegistry
  def register(_state, ref, handler) when is_binary(ref) do
    :ets.insert(__MODULE__, {ref, handler})
    {:ok, :default}
  end

  @impl Agora.Workflow.HandlerRegistry
  def resolve(_state, ref) when is_binary(ref) do
    case :ets.lookup(__MODULE__, ref) do
      [{^ref, handler}] -> {:ok, handler}
      [] -> Error.wrap(:workflow_error, "Handler not found: #{ref}")
    end
  end

  @impl Agora.Workflow.HandlerRegistry
  def handler_to_ref(_state, handler) do
    result =
      :ets.foldl(
        fn {ref, h}, acc ->
          if h == handler, do: ref, else: acc
        end,
        nil,
        __MODULE__
      )

    if result do
      {:ok, result}
    else
      Error.wrap(:workflow_error, "Handler not registered")
    end
  end

  @impl Agora.Workflow.HandlerRegistry
  def list(_state) do
    entries =
      :ets.foldl(
        fn {ref, handler}, acc -> Map.put(acc, ref, handler) end,
        %{},
        __MODULE__
      )

    {:ok, entries}
  end

  @impl Agora.Workflow.HandlerRegistry
  def unregister(_state, ref) when is_binary(ref) do
    :ets.delete(__MODULE__, ref)
    {:ok, :default}
  end
end
