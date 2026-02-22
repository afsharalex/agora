defmodule Agora do
  @moduledoc """
  Agora is a multi-agent runtime framework for Elixir.

  ## Quick Start

      # Define agents
      researcher = Agora.agent(:echo, "echo",
        name: "researcher", instructions: "You are a research analyst."
      )
      writer = Agora.agent(:echo, "echo",
        name: "writer", instructions: "You are a technical writer."
      )

      # Compose agents
      {:ok, results} = Agora.sequential("Write about BEAM", [researcher: researcher, writer: writer])

  ## Coordination Patterns

  | Function | Pattern | Use When |
  |----------|---------|----------|
  | `sequential/3` | A → B → C | Pipeline processing |
  | `parallel/3` | A \\| B \\| C | Independent subtasks |
  | `round_robin/3` | A → B → A → B | Iterative refinement |
  | `group_chat/3` | Shared transcript | Collaborative discussion |
  | `supervisor/4` | Delegation | Manager + workers |
  | `plan/4` | Planned execution | Complex multi-step tasks |
  | `handoff/3` | Baton passing | Decentralized routing |
  | `agent_tool/2` | Agent-as-tool | Hierarchical nesting |

  ## Single Agent

      config = Agora.AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, response} = Agora.run(config, "Hello")

  ## Advanced

  For deterministic DAG workflows with checkpoints and retries, see `Agora.run_workflow/2`
  and `Agora.Workflow.Builder`.

  For custom orchestration logic, implement the `Agora.Orchestrator` behaviour and use
  `Agora.start_runner/2` directly.
  """

  alias Agora.{AgentConfig, Error, Message}

  @doc """
  Defines an agent configuration.

  This is a convenience wrapper around `AgentConfig.new!/1` that takes the
  provider and model as positional arguments.

  ## Examples

      researcher = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
        name: "researcher",
        instructions: "You are a research analyst.",
        tools: [MyApp.SearchTool]
      )

  """
  @spec agent(atom(), String.t(), keyword()) :: AgentConfig.t()
  def agent(provider, model, opts \\ []) when is_atom(provider) and is_binary(model) do
    AgentConfig.new!(Keyword.merge(opts, provider: provider, model: model))
  end

  @doc """
  Creates a tool that delegates to another agent.

  See `Agora.AgentTool.new/2` for options and details.

  ## Examples

      research_tool = Agora.agent_tool(researcher,
        name: "research_agent",
        description: "Delegates research tasks to a specialized agent."
      )

  """
  @spec agent_tool(AgentConfig.t(), keyword()) :: Agora.Tool.FunctionTool.t()
  def agent_tool(%AgentConfig{} = config, opts \\ []) do
    Agora.AgentTool.new(config, opts)
  end

  # --- Composition API (delegates to Agora.Compose) ---

  defdelegate sequential(input, agents, opts \\ []), to: Agora.Compose
  defdelegate parallel(input, agents, opts \\ []), to: Agora.Compose
  defdelegate round_robin(input, agents, opts \\ []), to: Agora.Compose
  defdelegate group_chat(input, agents, opts \\ []), to: Agora.Compose
  defdelegate supervisor(input, leader, workers, opts \\ []), to: Agora.Compose
  defdelegate plan(input, planner, workers, opts \\ []), to: Agora.Compose
  defdelegate handoff(input, agents, opts \\ []), to: Agora.Compose

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

  This is an advanced API for custom orchestrator implementations.
  For built-in patterns, use the composition functions (`round_robin/3`,
  `supervisor/4`, etc.) instead.

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
