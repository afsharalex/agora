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

  ## Checkpoint Semantics

  Checkpoint save failures are always fatal regardless of `:on_failure` mode.
  A failed checkpoint write means the resumability guarantee is broken, so the
  executor surfaces it as `{:error, %Error{}}` even in `:skip` mode.

  """

  alias Agora.{AgentConfig, Error, Workflow}
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
    workflow_id = System.unique_integer([:positive])
    step_count = map_size(workflow.steps)

    Agora.Telemetry.span(
      [:agora, :workflow, :run],
      %{workflow_id: workflow_id, step_count: step_count},
      fn ->
        result = do_run(workflow, opts)

        stop_meta = %{workflow_id: workflow_id, step_count: step_count}

        stop_meta =
          case result do
            {:error, error} -> Map.put(stop_meta, :error, error)
            _ -> stop_meta
          end

        {result, stop_meta}
      end
    )
  end

  defp do_run(workflow, opts) do
    input = Keyword.get(opts, :input)
    on_failure = Keyword.get(opts, :on_failure, :abort)
    supervisor = Keyword.get(opts, :supervisor, @default_supervisor)
    checkpoint_config = Keyword.get(opts, :checkpoint_store)

    with {:ok, checkpoint_state} <- init_checkpoint(checkpoint_config),
         {:ok, levels} <- compute_levels(workflow),
         {:ok, checkpointed} <- load_checkpoint(checkpoint_state, workflow) do
      initial_results = Map.put(checkpointed, :input, input)

      execute_levels(
        levels,
        workflow,
        initial_results,
        on_failure,
        supervisor,
        checkpoint_state
      )
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

  defp execute_levels([], _workflow, results, _on_failure, _supervisor, _checkpoint) do
    {:ok, Map.delete(results, :input)}
  end

  defp execute_levels([level | rest], workflow, results, on_failure, supervisor, checkpoint) do
    {runnable, skipped} = partition_level(level, workflow, results)

    # Add skipped steps to results
    results = Enum.reduce(skipped, results, fn id, acc -> Map.put(acc, id, :skipped) end)

    if runnable == [] do
      execute_levels(rest, workflow, results, on_failure, supervisor, checkpoint)
    else
      level_start = System.monotonic_time(:millisecond)

      # Spawn all runnable steps
      task_entries =
        Enum.map(runnable, fn step_id ->
          step = Map.fetch!(workflow.steps, step_id)

          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              execute_step(step, results)
            end)

          {task, step}
        end)

      # Collect ALL results (deadline-based timeout, no short-circuit)
      step_outcomes = collect_all_results(task_entries, level_start)

      # Process outcomes
      {new_results, checkpoint, error} =
        process_outcomes(step_outcomes, results, checkpoint, on_failure)

      case error do
        nil ->
          execute_levels(rest, workflow, new_results, on_failure, supervisor, checkpoint)

        %Error{} = err ->
          # In abort mode, return all results collected so far (including failures)
          {:error, err}
      end
    end
  end

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

  defp execute_step(step, results) do
    Agora.Telemetry.span(
      [:agora, :workflow, :step],
      %{step_id: step.id, step_name: step.name},
      fn ->
        result = execute_with_retry(step, results, step.retry)

        stop_meta = %{step_id: step.id, step_name: step.name}

        stop_meta =
          case result do
            {:error, error} -> Map.put(stop_meta, :error, error)
            _ -> stop_meta
          end

        {result, stop_meta}
      end
    )
  end

  defp execute_with_retry(step, results, retries_left) do
    case execute_handler(step, results) do
      {:ok, _} = success ->
        success

      {:error, %Error{}} when retries_left > 0 ->
        execute_with_retry(step, results, retries_left - 1)

      {:error, %Error{}} = error ->
        error

      {:error, other} when retries_left > 0 ->
        # Non-Error term — normalize and retry
        _ = other
        execute_with_retry(step, results, retries_left - 1)

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
        execute_with_retry(step, results, retries_left - 1)
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
        execute_with_retry(step, results, retries_left - 1)
      else
        {:error,
         Error.new(
           :workflow_error,
           "Step #{inspect(step.id)} #{kind}: #{inspect(value)}"
         )}
      end
  end

  defp execute_handler(%Step{handler: handler}, results) when is_function(handler, 1) do
    handler.(results)
  end

  defp execute_handler(%Step{handler: %AgentConfig{} = config} = step, results) do
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

  defp process_outcomes(step_outcomes, results, checkpoint, on_failure) do
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

        # Track first error: step failure respects on_failure mode,
        # but checkpoint save failure is always fatal (integrity guarantee)
        error =
          case {outcome, on_failure, error, save_error} do
            {{:error, err}, :abort, nil, _} -> err
            {_, _, nil, %Error{} = se} -> se
            _ -> error
          end

        {results, checkpoint, error}
    end)
  end
end
