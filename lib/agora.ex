defmodule Agora do
  @moduledoc """
  Agora is a multi-agent runtime framework for Elixir.

  It enables users to create collaborative AI agents using the BEAM actor model,
  with provider abstraction, tool execution, middleware, and orchestration patterns.
  """

  alias Agora.{AgentConfig, Error, Execution, Message}

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
  One-shot agent execution: creates a temporary agent, runs the input, returns the result.

  The agent is always cleaned up after the call, even on error.

  ## Examples

      config = AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, response} = Agora.run(config, "Hello")

  """
  @spec run(AgentConfig.t(), String.t() | Message.t()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def run(%AgentConfig{} = config, input) do
    case Agora.Agent.Supervisor.start_agent(config) do
      {:ok, pid} ->
        try do
          Agora.Agent.run(pid, input)
        after
          Agora.Agent.Supervisor.stop_agent(pid)
        end

      {:error, reason} ->
        {:error, Error.new(:config_error, "Failed to start agent: #{inspect(reason)}")}
    end
  end

  @doc """
  One-shot streaming: creates a temporary agent, starts streaming, returns an enumerable.

  The agent is automatically stopped when the stream is fully consumed, halted early
  (e.g. via `Enum.take/2`), or if the calling process crashes. If the caller discards
  the stream without enumerating it, the agent will be cleaned up when the caller
  process exits.

  Returns `{:ok, Enumerable.t()}` (not `Agora.Stream.t()`) because the stream is
  wrapped with cleanup logic.

  ## Examples

      config = AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, stream} = Agora.stream(config, "Hello")

      stream
      |> Stream.filter(&(&1.type == :text_delta))
      |> Enum.each(fn event -> IO.write(event.data.text) end)

  """
  @spec stream(AgentConfig.t(), String.t() | Message.t()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%AgentConfig{} = config, input) do
    caller = self()

    case Agora.Agent.Supervisor.start_agent(config) do
      {:ok, pid} ->
        case Agora.Agent.stream_run(pid, input) do
          {:ok, agora_stream} ->
            stream_task_pid = agora_stream.pid

            spawn(fn ->
              caller_ref = Process.monitor(caller)
              agent_ref = Process.monitor(pid)

              receive do
                {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
                  cleanup_stream(stream_task_pid, pid)

                {:DOWN, ^agent_ref, :process, ^pid, _reason} ->
                  :ok
              end
            end)

            wrapped =
              Stream.transform(
                agora_stream,
                fn -> :ok end,
                fn event, :ok -> {[event], :ok} end,
                fn :ok -> cleanup_stream(stream_task_pid, pid) end
              )

            {:ok, wrapped}

          {:error, _} = error ->
            Agora.Agent.Supervisor.stop_agent(pid)
            error
        end

      {:error, reason} ->
        {:error, Error.new(:config_error, "Failed to start agent: #{inspect(reason)}")}
    end
  end

  # Stops the streaming relay task and then the agent process.
  # Both operations are idempotent — safe to call multiple times.
  defp cleanup_stream(stream_task_pid, agent_pid) do
    Process.exit(stream_task_pid, :shutdown)
    Agora.Agent.Supervisor.stop_agent(agent_pid)
  end

  @doc """
  Unified mode-first execution entry point.

  For orchestrator modes (`:single`, `:round_robin`, `:group_chat`, `:supervisor`):
  input is `String.t() | Message.t()`, `:agents` option required.

  For workflow modes:

    * `:dag` — input is `Workflow.t()` or module, workflow data via `:input` option
    * `:sequential` — input is `[step_spec()]`, a list of step tuples
    * `:conditional` — input is `{router_spec, [branch_spec()]}`, with optional `:merge`
    * `:parallel` — input is `[step_spec()]`, with optional `:from`/`:to` source/sink steps

  ## Examples

      # Orchestrator mode
      {:ok, response} = Agora.run_mode(:round_robin, "Hello",
        agents: %{a: config_a, b: config_b},
        termination: TerminationCondition.max_turns(5)
      )

      # Workflow modes
      {:ok, results} = Agora.run_mode(:dag, workflow, input: data)
      {:ok, results} = Agora.run_mode(:sequential, [{:a, &step_a/1}, {:b, &step_b/1}])
      {:ok, results} = Agora.run_mode(:parallel, branches, from: {:src, &source/1})

  """
  @spec run_mode(atom(), term(), keyword()) ::
          {:ok, Message.t() | map()} | {:error, Error.t()}
  def run_mode(mode, input, opts \\ [])

  def run_mode(mode, input, opts) when mode in [:dag, :sequential, :conditional, :parallel] do
    Execution.run_workflow(mode, input, opts)
  end

  def run_mode(mode, input, opts) do
    Execution.run(mode, input, opts)
  end

  @doc """
  Executes a workflow DAG.

  Accepts a `%Agora.Workflow{}` struct or a module atom that uses
  `Agora.Workflow.Definition` (has a `__workflow__/0` function).

  See `Agora.Workflow.Executor.run/2` for options.

  ## Examples

      # With a workflow struct
      {:ok, results} = Agora.run_workflow(workflow)

      # With a workflow module
      {:ok, results} = Agora.run_workflow(MyApp.Workflows.ETL)

  """
  @spec run_workflow(Agora.Workflow.t() | module(), keyword()) ::
          {:ok, map()} | {:error, Agora.Error.t()}
  def run_workflow(workflow_or_module, opts \\ [])

  def run_workflow(%Agora.Workflow{} = workflow, opts) do
    Agora.Workflow.Executor.run(workflow, opts)
  end

  def run_workflow(module, opts) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :__workflow__, 0) do
          try do
            workflow = module.__workflow__()
            Agora.Workflow.Executor.run(workflow, opts)
          rescue
            e ->
              {:error,
               Error.new(
                 :workflow_error,
                 "#{inspect(module)}.__workflow__/0 raised: #{Exception.message(e)}"
               )}
          end
        else
          {:error,
           Error.new(
             :workflow_error,
             "Module #{inspect(module)} does not define __workflow__/0. " <>
               "Did you `use Agora.Workflow.Definition`?"
           )}
        end

      {:error, reason} ->
        {:error,
         Error.new(
           :workflow_error,
           "Module #{inspect(module)} could not be loaded: #{inspect(reason)}"
         )}
    end
  end

  def run_workflow(other, _opts) do
    {:error,
     Error.new(
       :config_error,
       "run_workflow expects a %Workflow{} struct or a module atom, got: #{inspect(other)}"
     )}
  end
end
