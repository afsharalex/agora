defmodule Agora.Execution do
  @moduledoc """
  Unified mode-first execution facade for multi-agent orchestration and workflows.

  Provides two entry points:

    * `run/3` — for orchestrator modes (`:single`, `:round_robin`, `:group_chat`, `:supervisor`, `:plan`)
    * `run_workflow/3` — for workflow modes (`:dag`, `:sequential`, `:conditional`, `:parallel`)

  This module handles mode resolution, option validation, and lifecycle management
  (starting/stopping temporary Runner processes for orchestrator modes).

  ## Orchestrator Modes

  | Mode | Orchestrator | Description |
  |------|-------------|-------------|
  | `:single` | `Agora.Orchestrator.Single` | Single agent execution |
  | `:round_robin` | `Agora.Orchestrator.RoundRobin` | Cycle through agents |
  | `:group_chat` | `Agora.Orchestrator.GroupChat` | Shared transcript |
  | `:supervisor` | `Agora.Orchestrator.Supervisor` | Delegation pattern |
  | `:plan` | `Agora.Orchestrator.Plan` | Autonomous plan-execute-review |

  ## Workflow Modes

  | Mode | Input | Description |
  |------|-------|-------------|
  | `:dag` | `Workflow.t()` or module | DAG-based deterministic pipeline |
  | `:sequential` | `[step_spec()]` | Linear chain topology |
  | `:conditional` | `{router_spec, [branch_spec()]}` | Router with conditional branches |
  | `:parallel` | `[step_spec()]` | Fan-out/fan-in topology |

  ## Options (Orchestrator Modes)

    * `:agents` (required) — `%{atom() => AgentConfig.t()}`
    * `:termination` — termination condition function
    * `:max_turns` — hard safety limit (default 100)
    * `:cancel_token` — `%CancelToken{}`
    * `:context_policy` — `%ContextPolicy{}`
    * `:telemetry_metadata` — `map()` merged into telemetry events
    * `:orchestrator_opts` — forwarded to orchestrator `init/1`

  ## Options (Workflow Modes)

    * `:input` — initial input data for workflow steps
    * `:on_failure` — `:abort` or `:skip`
    * `:checkpoint_store` — `{module, keyword()}` for resumability
    * `:cancel_token` — `%CancelToken{}` for boundary-cooperative cancellation
    * `:context_policy` — `%ContextPolicy{}` injected into AgentConfig steps
    * `:telemetry_metadata` — `map()` merged into telemetry events

  """

  alias Agora.{ContextPolicy, Error, Message}
  alias Agora.Workflow.Patterns

  @orchestrator_modes %{
    single: Agora.Orchestrator.Single,
    round_robin: Agora.Orchestrator.RoundRobin,
    group_chat: Agora.Orchestrator.GroupChat,
    supervisor: Agora.Orchestrator.Supervisor,
    plan: Agora.Orchestrator.Plan
  }

  @workflow_modes [:dag, :sequential, :conditional, :parallel]

  @doc """
  Executes an orchestrator mode with the given input.

  Starts a temporary Runner process, runs the orchestration, and cleans up.
  """
  @spec run(atom(), String.t() | Message.t(), keyword()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def run(mode, input, opts \\ [])

  def run(mode, input, opts) do
    with {:ok, orchestrator_mod} <- resolve_orchestrator(mode),
         :ok <- validate_agents_present(opts) do
      run_orchestrator(orchestrator_mod, input, opts)
    end
  end

  @doc """
  Executes a workflow mode.

  ## Mode-specific input shapes

    * `:dag` — `Workflow.t()` or module implementing `Agora.Workflow.Definition`
    * `:sequential` — `[step_spec()]` list of step tuples
    * `:conditional` — `{router_spec, [branch_spec()]}` tuple
    * `:parallel` — `[step_spec()]` list of step tuples (`:from`/`:to` in opts)

  """
  @spec run_workflow(atom(), term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run_workflow(mode, workflow, opts \\ [])

  def run_workflow(:dag, workflow, opts) do
    Agora.run_workflow(workflow, opts)
  end

  def run_workflow(:sequential, steps, opts) when is_list(steps) do
    {pattern_opts, exec_opts} = split_pattern_opts(opts, [:step_defaults])

    with {:ok, workflow} <- Patterns.sequential(steps, pattern_opts),
         do: Agora.run_workflow(workflow, exec_opts)
  end

  def run_workflow(:sequential, input, _opts) do
    Error.wrap(
      :config_error,
      ":sequential mode expects a list of step specs [{id, handler} | {id, handler, opts}], " <>
        "got: #{inspect(input)}"
    )
  end

  def run_workflow(:conditional, {router, branches}, opts)
      when is_tuple(router) and is_list(branches) do
    {pattern_opts, exec_opts} = split_pattern_opts(opts, [:step_defaults, :merge])

    with {:ok, workflow} <- Patterns.conditional(router, branches, pattern_opts),
         do: Agora.run_workflow(workflow, exec_opts)
  end

  def run_workflow(:conditional, input, _opts) do
    Error.wrap(
      :config_error,
      ":conditional mode expects {router_spec, [branch_specs]}, got: #{inspect(input)}"
    )
  end

  def run_workflow(:parallel, branches, opts) when is_list(branches) do
    {pattern_opts, exec_opts} = split_pattern_opts(opts, [:step_defaults, :from, :to])

    with {:ok, workflow} <- Patterns.parallel(branches, pattern_opts),
         do: Agora.run_workflow(workflow, exec_opts)
  end

  def run_workflow(:parallel, input, _opts) do
    Error.wrap(
      :config_error,
      ":parallel mode expects a list of step specs, got: #{inspect(input)}"
    )
  end

  def run_workflow(mode, _workflow, _opts) do
    Error.wrap(:config_error, "Unknown workflow mode: #{inspect(mode)}", %{
      mode: mode,
      valid_modes: @workflow_modes
    })
  end

  @doc """
  Returns the map of known orchestrator modes to their modules.
  """
  @spec orchestrator_modes() :: %{atom() => module()}
  def orchestrator_modes, do: @orchestrator_modes

  @doc """
  Returns the list of known workflow modes.
  """
  @spec workflow_modes() :: [atom()]
  def workflow_modes, do: @workflow_modes

  # --- Private ---

  defp resolve_orchestrator(mode) do
    case Map.fetch(@orchestrator_modes, mode) do
      {:ok, mod} ->
        {:ok, mod}

      :error ->
        Error.wrap(:config_error, "Unknown orchestrator mode: #{inspect(mode)}", %{
          mode: mode,
          valid_modes: Map.keys(@orchestrator_modes) ++ @workflow_modes
        })
    end
  end

  defp run_orchestrator(orchestrator_mod, input, opts) do
    opts = maybe_inject_context_policy_middleware(opts)
    runner_opts = build_runner_opts(orchestrator_mod, opts)

    case Agora.Orchestrator.RunnerSupervisor.start_runner(runner_opts) do
      {:ok, pid} ->
        try do
          Agora.Orchestrator.Runner.run(pid, input)
        after
          Agora.Orchestrator.RunnerSupervisor.stop_runner(pid)
        end

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        Error.wrap(
          :orchestration_error,
          "Failed to start runner: #{inspect(reason)}"
        )
    end
  end

  defp build_runner_opts(orchestrator_mod, opts) do
    base = [
      orchestrator: orchestrator_mod,
      agents: Keyword.fetch!(opts, :agents),
      orchestrator_opts: Keyword.get(opts, :orchestrator_opts, []),
      termination: Keyword.get(opts, :termination),
      max_turns: Keyword.get(opts, :max_turns, 100)
    ]

    base
    |> maybe_put(:cancel_token, Keyword.get(opts, :cancel_token))
    |> maybe_put(:context_policy, Keyword.get(opts, :context_policy))
    |> maybe_put(:telemetry_metadata, Keyword.get(opts, :telemetry_metadata))
  end

  defp validate_agents_present(opts) do
    case Keyword.fetch(opts, :agents) do
      {:ok, agents} when is_map(agents) and map_size(agents) > 0 ->
        :ok

      {:ok, agents} when is_map(agents) ->
        Error.wrap(:config_error, ":agents map must not be empty")

      {:ok, _} ->
        Error.wrap(:config_error, ":agents must be a map of %{atom() => AgentConfig.t()}")

      :error ->
        Error.wrap(:config_error, "Missing required option: :agents")
    end
  end

  # When a context_policy is provided, inject a synthetic middleware closure
  # into each agent's middleware list. The closure runs at :before_provider_call
  # and compacts messages before they hit the provider.
  defp maybe_inject_context_policy_middleware(opts) do
    case Keyword.get(opts, :context_policy) do
      %ContextPolicy{strategy: :none} ->
        opts

      %ContextPolicy{} = policy ->
        compaction_mw = fn ctx, next ->
          if ctx.hook == :before_provider_call do
            next.(%{ctx | messages: ContextPolicy.apply(policy, ctx.messages)})
          else
            next.(ctx)
          end
        end

        agents =
          opts
          |> Keyword.fetch!(:agents)
          |> Map.new(fn {name, config} ->
            {name, %{config | middleware: [compaction_mw | config.middleware]}}
          end)

        Keyword.put(opts, :agents, agents)

      nil ->
        opts
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Split opts into pattern-builder opts and executor opts.
  # Pattern keys go to the builder, everything else goes to the executor.
  defp split_pattern_opts(opts, pattern_keys) do
    Enum.split_with(opts, fn {k, _v} -> k in pattern_keys end)
  end
end
