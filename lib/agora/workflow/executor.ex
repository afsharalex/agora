defmodule Agora.Workflow.Executor do
  @moduledoc """
  Stateless DAG executor for workflows.

  Performs topological sorting to identify execution levels, then runs each
  level in parallel using `Task.Supervisor`. Steps within the same level
  have no dependencies on each other and execute concurrently.

  ## Result Contract

  Every step in the returned map has one of three shapes:

    * `{:ok, value}` — step completed successfully
    * `{:error, %Error{}}` — step failed (only present in `:skip` mode)
    * `:skipped` — step skipped due to false conditions or cascaded failure

  ## Options

    * `:input` — initial input value available to all steps as `results[:input]`
    * `:on_failure` — `:abort` (default) or `:skip`
    * `:checkpoint_store` — `{module, keyword()}` tuple for checkpoint persistence
    * `:supervisor` — Task.Supervisor name (default: `Agora.WorkflowTaskSupervisor`)
    * `:cancel_token` — `%CancelToken{}` for boundary-cooperative cancellation
    * `:context_policy` — `%ContextPolicy{}` injected into AgentConfig step handlers
    * `:telemetry_metadata` — `map()` merged into workflow and step telemetry events

  ## Checkpoint Semantics

  Checkpoint save failures are always fatal regardless of `:on_failure` mode.
  A failed checkpoint write means the resumability guarantee is broken, so the
  executor surfaces it as `{:error, %Error{}}` even in `:skip` mode.

  ## Cancellation Semantics

  Cancellation is checked at two boundaries: before each level starts and inside
  each spawned task before step execution. Cancelled steps are never retried,
  and cancellation is globally terminal regardless of `:on_failure` mode.

  """

  require Logger

  alias Agora.{AgentConfig, CancelToken, ContextPolicy, Error, Workflow}
  alias Agora.Workflow.{CheckpointStore, Step}

  @default_supervisor Agora.WorkflowTaskSupervisor

  @type step_result :: {:ok, term()} | {:error, Error.t()} | :skipped

  @doc """
  Executes a workflow DAG.

  Returns `{:ok, %{atom() => step_result()}}` with results for all steps,
  or `{:error, %Error{}}` if the workflow fails in `:abort` mode.
  """
  @spec run(Workflow.t(), keyword()) :: {:ok, %{atom() => step_result()}} | {:error, Error.t()}
  def run(%Workflow{} = workflow, opts \\ []) do
    with :ok <- validate_cross_cutting_opts(opts) do
      workflow_id = System.unique_integer([:positive])
      step_count = map_size(workflow.steps)
      telemetry_metadata = Keyword.get(opts, :telemetry_metadata, %{})

      Agora.Telemetry.span(
        [:agora, :workflow, :run],
        Map.merge(telemetry_metadata, %{workflow_id: workflow_id, step_count: step_count}),
        fn ->
          result = do_run(workflow, opts)

          stop_meta =
            Map.merge(telemetry_metadata, %{workflow_id: workflow_id, step_count: step_count})

          stop_meta =
            case result do
              {:error, error} -> Map.put(stop_meta, :error, error)
              _ -> stop_meta
            end

          {result, stop_meta}
        end
      )
    end
  end

  defp do_run(workflow, opts) do
    input = Keyword.get(opts, :input)
    checkpoint_config = Keyword.get(opts, :checkpoint_store)

    run_ctx = %{
      on_failure: Keyword.get(opts, :on_failure, :abort),
      supervisor: Keyword.get(opts, :supervisor, @default_supervisor),
      cancel_token: Keyword.get(opts, :cancel_token),
      context_policy: Keyword.get(opts, :context_policy),
      telemetry_metadata: Keyword.get(opts, :telemetry_metadata, %{}),
      on_event: Keyword.get(opts, :on_event)
    }

    with {:ok, checkpoint_state} <- init_checkpoint(checkpoint_config),
         {:ok, levels} <- compute_levels(workflow),
         {:ok, checkpointed} <- load_checkpoint(checkpoint_state, workflow) do
      initial_results = Map.put(checkpointed, :input, input)
      execute_levels(levels, workflow, initial_results, run_ctx, checkpoint_state)
    end
  end

  # --- Checkpoint init/load ---

  defp init_checkpoint(nil), do: {:ok, nil}

  defp init_checkpoint({module, opts}) do
    CheckpointStore.init({module, opts})
  end

  defp load_checkpoint(nil, _workflow), do: {:ok, %{}}

  defp load_checkpoint(checkpoint_state, workflow) do
    known_ids = Map.keys(workflow.steps)
    CheckpointStore.load_all(checkpoint_state, known_ids)
  end

  # --- Level computation (Kahn's algorithm) ---

  defp compute_levels(%Workflow{steps: steps, edges: edges}) do
    step_ids = Map.keys(steps)
    in_degree = Map.new(step_ids, fn id -> {id, 0} end)

    in_degree =
      Enum.reduce(edges, in_degree, fn edge, acc ->
        Map.update!(acc, edge.to, &(&1 + 1))
      end)

    queue = Enum.filter(step_ids, fn id -> Map.get(in_degree, id) == 0 end) |> Enum.sort()
    build_levels(queue, edges, in_degree, [])
  end

  defp build_levels([], _edges, in_degree, levels) do
    unscheduled =
      in_degree
      |> Enum.reject(fn {id, _} -> Enum.any?(levels, &(id in &1)) end)
      |> Enum.map(fn {id, _} -> id end)

    if unscheduled == [] do
      {:ok, Enum.reverse(levels)}
    else
      Error.wrap(
        :workflow_error,
        "Workflow contains a cycle involving: #{inspect(Enum.sort(unscheduled))}"
      )
    end
  end

  defp build_levels(current_level, edges, in_degree, levels) do
    sorted_level = Enum.sort(current_level)

    # Compute next level by removing current nodes and decrementing successors
    new_in_degree =
      Enum.reduce(sorted_level, in_degree, fn node, acc ->
        successors = Enum.filter(edges, fn e -> e.from == node end) |> Enum.map(& &1.to)

        Enum.reduce(successors, acc, fn succ, deg ->
          Map.update!(deg, succ, &(&1 - 1))
        end)
      end)

    remaining_ids =
      new_in_degree
      |> Enum.reject(fn {id, _} -> id in sorted_level || Enum.any?(levels, &(id in &1)) end)

    next_queue =
      remaining_ids
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.sort()

    build_levels(next_queue, edges, new_in_degree, [sorted_level | levels])
  end

  # --- Level execution ---

  defp execute_levels([], _workflow, results, _run_ctx, _checkpoint) do
    {:ok, Map.delete(results, :input)}
  end

  defp execute_levels([level | rest], workflow, results, run_ctx, checkpoint) do
    # Check cancellation before each level
    if cancelled?(run_ctx) do
      {:error, Error.new(:cancelled, "Workflow execution cancelled")}
    else
      execute_level(level, rest, workflow, results, run_ctx, checkpoint)
    end
  end

  defp execute_level(level, rest, workflow, results, run_ctx, checkpoint) do
    {runnable, skipped} = partition_level(level, workflow, results)

    # Add skipped steps to results
    results = Enum.reduce(skipped, results, fn id, acc -> Map.put(acc, id, :skipped) end)

    if runnable == [] do
      execute_levels(rest, workflow, results, run_ctx, checkpoint)
    else
      level_start = System.monotonic_time(:millisecond)

      # Spawn all runnable steps
      task_entries =
        Enum.map(runnable, fn step_id ->
          step = Map.fetch!(workflow.steps, step_id)

          task =
            Task.Supervisor.async_nolink(run_ctx.supervisor, fn ->
              if cancelled?(run_ctx) do
                {:error, Error.new(:cancelled, "Step cancelled")}
              else
                execute_step(step, results, run_ctx)
              end
            end)

          {task, step}
        end)

      # Collect ALL results (deadline-based timeout, no short-circuit)
      step_outcomes = collect_all_results(task_entries, level_start)

      # Process outcomes
      {new_results, checkpoint, error} =
        process_outcomes(step_outcomes, results, checkpoint, run_ctx)

      case error do
        nil ->
          execute_levels(rest, workflow, new_results, run_ctx, checkpoint)

        %Error{} = err ->
          {:error, err}
      end
    end
  end

  # --- Cancellation check ---

  defp cancelled?(%{cancel_token: nil}), do: false
  defp cancelled?(%{cancel_token: token}), do: CancelToken.cancelled?(token)

  # --- Step partitioning (conditional edge resolution) ---

  defp partition_level(step_ids, workflow, results) do
    Enum.split_with(step_ids, fn step_id ->
      # Skip already-checkpointed steps
      if Map.has_key?(results, step_id) do
        false
      else
        should_run?(step_id, workflow, results)
      end
    end)
    |> then(fn {runnable, maybe_skip} ->
      # Steps that are checkpointed go into neither runnable nor skipped
      {checkpointed, truly_skippable} =
        Enum.split_with(maybe_skip, fn id -> Map.has_key?(results, id) end)

      # Checkpointed steps are already in results, no action needed
      _ = checkpointed
      {runnable, truly_skippable}
    end)
  end

  defp should_run?(step_id, workflow, results) do
    incoming_edges = Enum.filter(workflow.edges, fn e -> e.to == step_id end)

    # Steps with no incoming edges always run
    if incoming_edges == [] do
      true
    else
      edge_states = Enum.map(incoming_edges, fn edge -> resolve_edge(edge, results) end)

      has_condition_error = Enum.any?(edge_states, &(&1 == :condition_error))
      has_failed_dep = Enum.any?(edge_states, &(&1 == :failed_dep))
      has_pending = Enum.any?(edge_states, &(&1 == :pending))

      all_satisfied_or_not_required =
        Enum.all?(edge_states, &(&1 in [:satisfied, :not_required]))

      has_satisfied = Enum.any?(edge_states, &(&1 == :satisfied))

      cond do
        # Condition crash → skip (safe default)
        has_condition_error -> false
        # Any pending → not ready
        has_pending -> false
        # Any failed dep → skip (cascade)
        has_failed_dep -> false
        # All edges satisfied or not_required, and at least one satisfied → run
        all_satisfied_or_not_required and has_satisfied -> true
        # All not_required (no data flowing in) → skip
        true -> false
      end
    end
  end

  defp resolve_edge(edge, results) do
    case Map.get(results, edge.from) do
      nil ->
        :pending

      {:ok, _value} ->
        if edge.condition do
          eval_condition(edge.condition, results)
        else
          :satisfied
        end

      {:error, _} ->
        :failed_dep

      :skipped ->
        if edge.optional, do: :not_required, else: :failed_dep
    end
  end

  defp eval_condition(condition, results) do
    if condition.(results), do: :satisfied, else: :not_required
  rescue
    _exception -> :condition_error
  catch
    _kind, _value -> :condition_error
  end

  # --- Step execution with retry ---

  defp execute_step(step, results, run_ctx) do
    safe_on_event(run_ctx, %{type: :step_started, step_id: step.id})

    result =
      Agora.Telemetry.span(
        [:agora, :workflow, :step],
        Map.merge(run_ctx.telemetry_metadata, %{step_id: step.id, step_name: step.name}),
        fn ->
          result = execute_with_retry(step, results, step.retry, run_ctx)

          stop_meta =
            Map.merge(run_ctx.telemetry_metadata, %{step_id: step.id, step_name: step.name})

          stop_meta =
            case result do
              {:error, error} -> Map.put(stop_meta, :error, error)
              _ -> stop_meta
            end

          {result, stop_meta}
        end
      )

    step_result =
      case result do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end

    safe_on_event(run_ctx, %{type: :step_completed, step_id: step.id, result: step_result})

    result
  end

  defp execute_with_retry(step, results, retries_left, run_ctx) do
    case execute_handler(step, results, run_ctx) do
      {:ok, _} = success ->
        success

      # Cancelled steps are never retried
      {:error, %Error{type: :cancelled}} = error ->
        error

      {:error, %Error{}} when retries_left > 0 ->
        execute_with_retry(step, results, retries_left - 1, run_ctx)

      {:error, %Error{}} = error ->
        error

      {:error, other} when retries_left > 0 ->
        # Non-Error term — normalize and retry
        _ = other
        execute_with_retry(step, results, retries_left - 1, run_ctx)

      {:error, other} ->
        {:error,
         Error.new(
           :workflow_error,
           "Step #{inspect(step.id)} returned non-Error: #{inspect(other)}"
         )}

      other ->
        {:error,
         Error.new(
           :workflow_error,
           "Step #{inspect(step.id)} returned unexpected: #{inspect(other)}"
         )}
    end
  rescue
    exception ->
      if retries_left > 0 do
        execute_with_retry(step, results, retries_left - 1, run_ctx)
      else
        {:error,
         Error.new(
           :workflow_error,
           "Step #{inspect(step.id)} raised: #{Exception.message(exception)}"
         )}
      end
  catch
    kind, value ->
      if retries_left > 0 do
        execute_with_retry(step, results, retries_left - 1, run_ctx)
      else
        {:error,
         Error.new(
           :workflow_error,
           "Step #{inspect(step.id)} #{kind}: #{inspect(value)}"
         )}
      end
  end

  defp execute_handler(%Step{handler: handler}, results, _run_ctx)
       when is_function(handler, 1) do
    handler.(results)
  end

  defp execute_handler(%Step{handler: %AgentConfig{} = config} = step, results, run_ctx) do
    config =
      maybe_inject_context_policy(config, run_ctx.context_policy, run_ctx.telemetry_metadata)

    message = build_agent_message(step, results)

    case Agora.Agent.Supervisor.start_agent(config) do
      {:ok, pid} ->
        try do
          case Agora.Agent.run(pid, message) do
            {:ok, response} -> {:ok, response}
            {:error, _} = error -> error
          end
        after
          Agora.Agent.Supervisor.stop_agent(pid)
        end

      {:error, reason} ->
        Error.wrap(
          :workflow_error,
          "Failed to start agent for step #{inspect(step.id)}: #{inspect(reason)}"
        )
    end
  end

  defp maybe_inject_context_policy(config, nil, _telemetry_metadata), do: config

  defp maybe_inject_context_policy(config, %ContextPolicy{strategy: :none}, _telemetry_metadata),
    do: config

  defp maybe_inject_context_policy(config, %ContextPolicy{} = policy, telemetry_metadata) do
    compaction_mw = fn ctx, next ->
      if ctx.hook == :before_provider_call do
        before_count = length(ctx.messages)
        compacted = ContextPolicy.apply(policy, ctx.messages)
        after_count = length(compacted)

        if after_count < before_count do
          Agora.Telemetry.emit(
            [:agora, :mode, :context_compacted],
            %{system_time: System.system_time()},
            Map.merge(telemetry_metadata, %{
              strategy: policy.strategy,
              before: before_count,
              after: after_count
            })
          )
        end

        next.(%{ctx | messages: compacted})
      else
        next.(ctx)
      end
    end

    %{config | middleware: [compaction_mw | config.middleware]}
  end

  defp build_agent_message(%Step{input_mapper: mapper}, results) when is_function(mapper, 1) do
    mapper.(results)
  end

  defp build_agent_message(%Step{input_mapper: nil}, results) do
    # Default: JSON-encode successful upstream results (stable, parseable)
    results
    |> Map.delete(:input)
    |> Enum.filter(fn {_k, v} -> match?({:ok, _}, v) end)
    |> Map.new(fn {k, {:ok, v}} -> {to_string(k), v} end)
    |> Jason.encode!()
  end

  # --- Result collection (deadline-based) ---

  defp collect_all_results(task_entries, level_start_time) do
    Enum.map(task_entries, fn {task, step} ->
      elapsed_ms = System.monotonic_time(:millisecond) - level_start_time
      remaining = max(step.timeout - elapsed_ms, 0)

      outcome =
        case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            result

          {:exit, reason} ->
            {:error,
             Error.new(:workflow_error, "Step #{inspect(step.id)} exited: #{inspect(reason)}")}

          nil ->
            {:error, Error.new(:timeout, "Step #{inspect(step.id)} timed out")}
        end

      {step, outcome}
    end)
  end

  # --- Outcome processing ---

  defp process_outcomes(step_outcomes, results, checkpoint, run_ctx) do
    Enum.reduce(step_outcomes, {results, checkpoint, nil}, fn
      {step, outcome}, {results, checkpoint, error} ->
        results = Map.put(results, step.id, outcome)

        # Save successful results to checkpoint
        {checkpoint, save_error} =
          case {outcome, checkpoint} do
            {{:ok, _}, {_mod, _state} = cs} ->
              case CheckpointStore.save(cs, step.id, outcome) do
                {:ok, new_cs} ->
                  {new_cs, nil}

                {:error, save_err} ->
                  {checkpoint,
                   Error.new(
                     :workflow_error,
                     "Checkpoint save failed for step #{inspect(step.id)}: #{save_err.message}"
                   )}
              end

            _ ->
              {checkpoint, nil}
          end

        # Track first error: cancellation is always terminal,
        # step failure respects on_failure mode,
        # checkpoint save failure is always fatal (integrity guarantee)
        error =
          case {outcome, run_ctx.on_failure, error, save_error} do
            # Cancellation is always terminal regardless of on_failure mode
            {{:error, %Error{type: :cancelled} = err}, _, nil, _} -> err
            {{:error, err}, :abort, nil, _} -> err
            {_, _, nil, %Error{} = se} -> se
            _ -> error
          end

        {results, checkpoint, error}
    end)
  end

  # --- on_event callback (safe-wrapped) ---

  defp safe_on_event(%{on_event: nil}, _event), do: :ok

  defp safe_on_event(%{on_event: on_event}, event) do
    on_event.(event)
    :ok
  rescue
    e ->
      Logger.warning("on_event callback raised: #{Exception.message(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("on_event callback #{kind}: #{inspect(value)}")
      :ok
  end

  # --- Option validation ---

  defp validate_cross_cutting_opts(opts) do
    cancel_token = Keyword.get(opts, :cancel_token)
    context_policy = Keyword.get(opts, :context_policy)
    telemetry_metadata = Keyword.get(opts, :telemetry_metadata, %{})

    cond do
      cancel_token != nil and not match?(%CancelToken{}, cancel_token) ->
        Error.wrap(
          :config_error,
          ":cancel_token must be a %CancelToken{} struct, got: #{inspect(cancel_token)}"
        )

      context_policy != nil and not match?(%ContextPolicy{}, context_policy) ->
        Error.wrap(
          :config_error,
          ":context_policy must be a %ContextPolicy{} struct, got: #{inspect(context_policy)}"
        )

      not is_map(telemetry_metadata) ->
        Error.wrap(
          :config_error,
          ":telemetry_metadata must be a map, got: #{inspect(telemetry_metadata)}"
        )

      true ->
        :ok
    end
  end
end
