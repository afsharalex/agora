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
    * `:checkpoint_id` — resume from a specific checkpoint (validates compatibility)
    * `:checkpoint_version` — specific snapshot version to resume from (default: `:latest`)
    * `:skip_compatibility_check` — bypass workflow hash verification (default: `false`)
    * `:checkpoint_metadata` — extra metadata stored with checkpoint (`map()`)
    * `:retention` — retention policy options (e.g., `[max_completed: 5]`), applied after successful completion
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
  alias Agora.Workflow.{Checkpoint, CheckpointStore, Step}

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
    checkpoint_id = Keyword.get(opts, :checkpoint_id)
    checkpoint_version = Keyword.get(opts, :checkpoint_version, :latest)
    skip_compat = Keyword.get(opts, :skip_compatibility_check, false)
    checkpoint_metadata = Keyword.get(opts, :checkpoint_metadata, %{})
    retention_opts = Keyword.get(opts, :retention)

    run_ctx = %{
      on_failure: Keyword.get(opts, :on_failure, :abort),
      supervisor: Keyword.get(opts, :supervisor, @default_supervisor),
      cancel_token: Keyword.get(opts, :cancel_token),
      context_policy: Keyword.get(opts, :context_policy),
      telemetry_metadata: Keyword.get(opts, :telemetry_metadata, %{}),
      on_event: Keyword.get(opts, :on_event),
      checkpoint_config: checkpoint_config,
      retention: retention_opts
    }

    with {:ok, cs0} <- init_checkpoint(checkpoint_config),
         {:ok, cs1} <- maybe_lock(cs0, checkpoint_id, run_ctx) do
      # Use a unique process dict key to avoid collisions with nested executor calls
      cs_key = {__MODULE__, :latest_cs, make_ref()}
      Process.put(cs_key, cs1)

      try do
        with {:ok, levels} <- compute_levels(workflow),
             {:ok, {checkpoint, checkpointed, cs2}} <-
               resolve_checkpoint(
                 cs1,
                 checkpoint_id,
                 checkpoint_version,
                 workflow,
                 skip_compat,
                 checkpoint_metadata
               ) do
          initial_results = Map.put(checkpointed, :input, input)
          Process.put(cs_key, cs2)

          case execute_levels(levels, workflow, initial_results, run_ctx, cs2, checkpoint) do
            {:ok, results, cs3, updated_checkpoint} ->
              Process.put(cs_key, cs3)
              finalize_checkpoint(cs3, updated_checkpoint, :completed, results, run_ctx)
              {:ok, results}

            {:error, reason, accumulated_results, cs3, updated_checkpoint} ->
              Process.put(cs_key, cs3)
              finalize_checkpoint(cs3, updated_checkpoint, :failed, accumulated_results, run_ctx)
              {:error, reason}
          end
        end
      after
        latest_cs = Process.delete(cs_key)
        maybe_unlock(latest_cs, checkpoint_id)
      end
    end
  end

  # --- Checkpoint init/load/resolve ---

  defp init_checkpoint(nil), do: {:ok, nil}

  defp init_checkpoint({module, opts}) do
    CheckpointStore.init({module, opts})
  end

  defp maybe_lock(nil, _checkpoint_id, _run_ctx), do: {:ok, nil}
  defp maybe_lock(cs, nil, _run_ctx), do: {:ok, cs}

  defp maybe_lock(cs, checkpoint_id, run_ctx) do
    case CheckpointStore.lock(cs, checkpoint_id) do
      {:ok, new_cs} ->
        Agora.Telemetry.emit(
          [:agora, :workflow, :checkpoint, :lock],
          %{system_time: System.system_time()},
          Map.merge(run_ctx.telemetry_metadata, %{checkpoint_id: checkpoint_id, acquired: true})
        )

        {:ok, new_cs}

      {:error, _} = error ->
        Agora.Telemetry.emit(
          [:agora, :workflow, :checkpoint, :lock],
          %{system_time: System.system_time()},
          Map.merge(run_ctx.telemetry_metadata, %{checkpoint_id: checkpoint_id, acquired: false})
        )

        error
    end
  end

  defp maybe_unlock(nil, _checkpoint_id), do: :ok
  defp maybe_unlock(_cs, nil), do: :ok

  defp maybe_unlock(cs, checkpoint_id) do
    CheckpointStore.unlock(cs, checkpoint_id)
    :ok
  end

  defp resolve_checkpoint(cs, nil, _version, workflow, _skip_compat, checkpoint_metadata) do
    # No checkpoint_id — start fresh, optionally use legacy load_all
    case load_checkpoint_legacy(cs, workflow) do
      {:ok, checkpointed} ->
        checkpoint =
          if cs do
            Checkpoint.new(workflow, metadata: checkpoint_metadata)
          else
            nil
          end

        {:ok, {checkpoint, checkpointed, cs}}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_checkpoint(cs, checkpoint_id, version, workflow, skip_compat, checkpoint_metadata) do
    case CheckpointStore.load_snapshot(cs, checkpoint_id, version) do
      {:ok, nil} ->
        # No snapshot found — start fresh with this ID
        checkpoint = Checkpoint.new(workflow, id: checkpoint_id, metadata: checkpoint_metadata)
        {:ok, {checkpoint, %{}, cs}}

      {:ok, %Checkpoint{} = checkpoint} ->
        Agora.Telemetry.emit(
          [:agora, :workflow, :checkpoint, :load],
          %{system_time: System.system_time()},
          %{
            checkpoint_id: checkpoint_id,
            version: checkpoint.version,
            loaded_steps: MapSet.size(checkpoint.completed_steps)
          }
        )

        if skip_compat do
          {:ok, {checkpoint, checkpoint.results, cs}}
        else
          case Checkpoint.check_compatibility(checkpoint, workflow) do
            :ok ->
              {:ok, {checkpoint, checkpoint.results, cs}}

            {:error, _} = error ->
              error
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp load_checkpoint_legacy(nil, _workflow), do: {:ok, %{}}

  defp load_checkpoint_legacy(checkpoint_state, workflow) do
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

  # execute_levels returns {:ok, results, checkpoint_state, checkpoint}
  # or {:error, reason, accumulated_results, checkpoint_state, checkpoint}

  defp execute_levels([], _workflow, results, _run_ctx, checkpoint_state, checkpoint) do
    {:ok, Map.delete(results, :input), checkpoint_state, checkpoint}
  end

  defp execute_levels([level | rest], workflow, results, run_ctx, checkpoint_state, checkpoint) do
    if cancelled?(run_ctx) do
      {:error, Error.new(:cancelled, "Workflow execution cancelled"), Map.delete(results, :input),
       checkpoint_state, checkpoint}
    else
      execute_level(level, rest, workflow, results, run_ctx, checkpoint_state, checkpoint)
    end
  end

  defp execute_level(level, rest, workflow, results, run_ctx, checkpoint_state, checkpoint) do
    {runnable, skipped} = partition_level(level, workflow, results)

    # Add skipped steps to results
    results = Enum.reduce(skipped, results, fn id, acc -> Map.put(acc, id, :skipped) end)

    if runnable == [] do
      execute_levels(rest, workflow, results, run_ctx, checkpoint_state, checkpoint)
    else
      level_start = System.monotonic_time(:millisecond)

      cancel_token = run_ctx.cancel_token

      task_entries =
        Enum.map(runnable, fn step_id ->
          step = Map.fetch!(workflow.steps, step_id)

          task =
            if cancel_token do
              t =
                Task.Supervisor.async_nolink(run_ctx.supervisor, fn ->
                  receive do
                    :registered ->
                      if cancelled?(run_ctx) do
                        {:error, Error.new(:cancelled, "Step cancelled")}
                      else
                        execute_step(step, results, run_ctx)
                      end
                  end
                end)

              CancelToken.register(cancel_token, t.pid)
              send(t.pid, :registered)
              t
            else
              Task.Supervisor.async_nolink(run_ctx.supervisor, fn ->
                if cancelled?(run_ctx) do
                  {:error, Error.new(:cancelled, "Step cancelled")}
                else
                  execute_step(step, results, run_ctx)
                end
              end)
            end

          {task, step}
        end)

      step_outcomes = collect_all_results(task_entries, level_start, cancel_token)

      {new_results, checkpoint_state, checkpoint, error} =
        process_outcomes(step_outcomes, results, checkpoint_state, checkpoint, run_ctx)

      case error do
        nil ->
          # Save snapshot after each level
          checkpoint_state = save_snapshot_after_level(checkpoint_state, checkpoint, run_ctx)
          execute_levels(rest, workflow, new_results, run_ctx, checkpoint_state, checkpoint)

        %Error{} = err ->
          {:error, err, Map.delete(new_results, :input), checkpoint_state, checkpoint}
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
    cancel_token = run_ctx.cancel_token
    opts = if cancel_token, do: [cancel_token: cancel_token], else: []

    case Agora.Agent.Supervisor.start_agent(config) do
      {:ok, pid} ->
        try do
          case Agora.Agent.run(pid, message, opts) do
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

  defp collect_all_results(task_entries, level_start_time, cancel_token) do
    Enum.map(task_entries, fn {task, step} ->
      elapsed_ms = System.monotonic_time(:millisecond) - level_start_time
      remaining = max(step.timeout - elapsed_ms, 0)

      outcome =
        case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            result

          {:exit, :killed} ->
            {:error, Error.new(:cancelled, "Step #{inspect(step.id)} killed")}

          {:exit, reason} ->
            {:error,
             Error.new(:workflow_error, "Step #{inspect(step.id)} exited: #{inspect(reason)}")}

          nil ->
            {:error, Error.new(:timeout, "Step #{inspect(step.id)} timed out")}
        end

      # Unregister step task from cancel group
      if cancel_token, do: CancelToken.unregister(cancel_token, task.pid)

      {step, outcome}
    end)
  end

  # --- Outcome processing ---

  defp process_outcomes(step_outcomes, results, checkpoint_state, checkpoint, run_ctx) do
    # Collect all outcomes, then update checkpoint once for the entire level
    {results, cs, error, level_results} =
      Enum.reduce(step_outcomes, {results, checkpoint_state, nil, %{}}, fn
        {step, outcome}, {results, cs, error, level_results} ->
          results = Map.put(results, step.id, outcome)
          level_results = Map.put(level_results, step.id, outcome)

          # Save successful results to checkpoint store (legacy per-step save)
          {cs, save_error} =
            case {outcome, cs} do
              {{:ok, _}, {_mod, _state} = store} ->
                case CheckpointStore.save(store, step.id, outcome) do
                  {:ok, new_store} ->
                    {new_store, nil}

                  {:error, save_err} ->
                    {cs,
                     Error.new(
                       :workflow_error,
                       "Checkpoint save failed for step #{inspect(step.id)}: #{save_err.message}"
                     )}
                end

              _ ->
                {cs, nil}
            end

          error =
            case {outcome, run_ctx.on_failure, error, save_error} do
              {{:error, %Error{type: :cancelled} = err}, _, nil, _} -> err
              {{:error, err}, :abort, nil, _} -> err
              {_, _, nil, %Error{} = se} -> se
              _ -> error
            end

          {results, cs, error, level_results}
      end)

    # Update checkpoint once with all level results
    cp =
      if checkpoint && map_size(level_results) > 0,
        do: Checkpoint.record_level_results(checkpoint, level_results),
        else: checkpoint

    {results, cs, cp, error}
  end

  # --- Snapshot save/finalize ---

  defp save_snapshot_after_level(nil, _checkpoint, _run_ctx), do: nil
  defp save_snapshot_after_level(cs, nil, _run_ctx), do: cs

  defp save_snapshot_after_level(cs, checkpoint, run_ctx) do
    case CheckpointStore.save_snapshot(cs, checkpoint) do
      {:ok, new_cs} ->
        Agora.Telemetry.emit(
          [:agora, :workflow, :checkpoint, :save],
          %{system_time: System.system_time()},
          Map.merge(run_ctx.telemetry_metadata, %{
            checkpoint_id: checkpoint.id,
            version: checkpoint.version,
            step_count: MapSet.size(checkpoint.completed_steps)
          })
        )

        new_cs

      {:error, _} ->
        # Snapshot save failure is non-fatal — fall back to per-step save
        cs
    end
  end

  defp finalize_checkpoint(nil, _checkpoint, _status, _results, _run_ctx), do: :ok
  defp finalize_checkpoint(_cs, nil, _status, _results, _run_ctx), do: :ok

  defp finalize_checkpoint(cs, checkpoint, status, results, run_ctx) do
    finalized = %{Checkpoint.finalize(checkpoint, status) | results: results}

    case CheckpointStore.save_snapshot(cs, finalized) do
      {:ok, _} ->
        Agora.Telemetry.emit(
          [:agora, :workflow, :checkpoint, :finalize],
          %{system_time: System.system_time()},
          Map.merge(run_ctx.telemetry_metadata, %{
            checkpoint_id: finalized.id,
            status: finalized.status,
            version: finalized.version
          })
        )

        # Apply retention after successful completion (best-effort)
        if status == :completed && run_ctx.retention && run_ctx.checkpoint_config do
          try do
            Checkpoint.apply_retention(run_ctx.checkpoint_config, run_ctx.retention)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end

      {:error, _} ->
        # Best-effort finalization
        :ok
    end
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
