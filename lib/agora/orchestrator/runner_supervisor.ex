defmodule Agora.Orchestrator.RunnerSupervisor do
  @moduledoc """
  DynamicSupervisor for orchestration Runner processes.

  Runners are started as `:temporary` children — they are not restarted on crash
  since orchestration state would be lost.
  """

  use DynamicSupervisor

  @doc """
  Starts the runner supervisor, registered under `Agora.Orchestrator.RunnerSupervisor`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a Runner process under this supervisor.

  See `Agora.Orchestrator.Runner.start_link/1` for options.
  """
  @spec start_runner(keyword(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_runner(opts, server_opts \\ []) do
    opts = Keyword.merge(opts, server_opts)
    child_spec = {Agora.Orchestrator.Runner, opts}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Stops a Runner process by pid.
  """
  @spec stop_runner(pid()) :: :ok | {:error, :not_found}
  def stop_runner(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
