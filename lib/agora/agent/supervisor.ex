defmodule Agora.Agent.Supervisor do
  @moduledoc """
  DynamicSupervisor for agent processes.

  Agents without memory are started as `:temporary` children (not restarted on crash).
  Agents with a memory backend configured are started as `:transient` — they can be
  restarted by the supervisor and will reload conversation history from the memory
  backend on init.
  """

  use DynamicSupervisor

  @doc """
  Starts the agent supervisor, registered under `Agora.Agent.Supervisor`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts an agent process under this supervisor.

  ## Options

    * `:config` (required) — an `%AgentConfig{}` struct
    * `:name` — optional GenServer name registration

  """
  @spec start_agent(Agora.AgentConfig.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(%Agora.AgentConfig{} = config, opts \\ []) do
    child_spec = {Agora.Agent, Keyword.put(opts, :config, config)}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Stops an agent process by pid.
  """
  @spec stop_agent(pid()) :: :ok | {:error, :not_found}
  def stop_agent(pid) when is_pid(pid) do
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
