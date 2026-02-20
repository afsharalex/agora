defmodule Agora do
  @moduledoc """
  Agora is a multi-agent runtime framework for Elixir.

  It enables users to create collaborative AI agents using the BEAM actor model,
  with provider abstraction, tool execution, middleware, and orchestration patterns.
  """

  alias Agora.AgentConfig

  @doc """
  Returns the current version of Agora.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:agora, :vsn) |> to_string()
  end

  @doc """
  Starts an agent process under the agent supervisor.

  See `Agora.Agent.Supervisor.start_agent/2` for options.
  """
  @spec start_agent(AgentConfig.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(%AgentConfig{} = config, opts \\ []) do
    Agora.Agent.Supervisor.start_agent(config, opts)
  end

  @doc """
  Stops an agent process by pid.
  """
  @spec stop_agent(pid()) :: :ok | {:error, :not_found}
  def stop_agent(pid) when is_pid(pid) do
    Agora.Agent.Supervisor.stop_agent(pid)
  end

  @doc """
  Starts an orchestration Runner process under the runner supervisor.

  See `Agora.Orchestrator.Runner.start_link/1` for options.
  """
  @spec start_runner(keyword(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_runner(opts, server_opts \\ []) do
    Agora.Orchestrator.RunnerSupervisor.start_runner(opts, server_opts)
  end

  @doc """
  Stops a Runner process by pid.
  """
  @spec stop_runner(pid()) :: :ok | {:error, :not_found}
  def stop_runner(pid) when is_pid(pid) do
    Agora.Orchestrator.RunnerSupervisor.stop_runner(pid)
  end

  @doc """
  Sends a message and returns a stream of incremental events.

  Convenience wrapper for `Agora.Agent.stream_run/2`.
  """
  @spec stream_run(GenServer.server(), String.t() | Agora.Message.t()) ::
          {:ok, Agora.Stream.t()} | {:error, Agora.Error.t()}
  def stream_run(agent, input) do
    Agora.Agent.stream_run(agent, input)
  end

  @doc """
  Executes a workflow DAG.

  See `Agora.Workflow.Executor.run/2` for options.
  """
  @spec run_workflow(Agora.Workflow.t(), keyword()) ::
          {:ok, map()} | {:error, Agora.Error.t()}
  def run_workflow(%Agora.Workflow{} = workflow, opts \\ []) do
    Agora.Workflow.Executor.run(workflow, opts)
  end
end
