defmodule Agora.Orchestrator.Plan do
  @moduledoc """
  Autonomous plan-based orchestrator where a planner agent creates a structured
  plan, assigns steps to specialist workers, and reviews results.

  The planner creates a DAG of steps with dependencies, each assigned to a worker
  agent. Steps execute in dependency order, and after each step the planner reviews
  the result and can CONTINUE, RETRY, REASSIGN, REPLAN, or declare COMPLETE.

  ## Config

    * `config.agent_names` (required) — all agent names (planner + workers)
    * `config.planner_agent` (required) — atom name of the planner agent
    * `config.max_retries_per_step` (optional, default `2`) — per-step retry limit
    * `config.max_replans` (optional, default `2`) — replan limit
    * `config.max_plan_steps` (optional, default `10`) — max steps in a plan
    * `config.parse_plan` (optional) — custom 2-arity parser function
      `(response_content, agent_lookup) -> {:ok, [step]} | {:error, Error.t()}`
    * `config.parse_review` (optional) — custom 1-arity parser function
      `(response_content) -> {:ok, review_decision} | {:error, Error.t()}`

  ## Plan Format

  The planner outputs a structured plan between `PLAN` and `END_PLAN` markers:

      PLAN
      STEP:1:researcher:Research the topic
      STEP:2:writer:Write the draft:DEP:1
      STEP:3:reviewer:Review and edit the draft:DEP:2
      END_PLAN

  ## Review Format

  After each step, the planner reviews with one of:

      REVIEW:COMPLETE:summary text
      REVIEW:CONTINUE:reason
      REVIEW:RETRY:reason
      REVIEW:REASSIGN:agent_name:reason
      REVIEW:REPLAN:reason

  ## Safety

  Parsed agent names are validated against a known lookup map.
  `String.to_atom/1` is never called on model output to prevent atom table
  exhaustion. Plan graphs are validated for duplicate IDs, unknown deps,
  self-deps, and cycles.
  """

  @behaviour Agora.Orchestrator

  alias Agora.{Error, Message}

  @default_max_retries 2
  @default_max_replans 2
  @default_max_plan_steps 10

  @impl true
  def init(config) do
    with {:ok, planner} <- fetch_planner(config),
         {:ok, all_agents} <- fetch_agents(config, planner),
         {:ok, parse_plan} <- validate_parse_plan(Map.get(config, :parse_plan)),
         {:ok, parse_review} <- validate_parse_review(Map.get(config, :parse_review)),
         {:ok, max_retries} <- validate_limit(config, :max_retries_per_step, @default_max_retries),
         {:ok, max_replans} <- validate_limit(config, :max_replans, @default_max_replans),
         {:ok, max_plan_steps} <- validate_limit(config, :max_plan_steps, @default_max_plan_steps) do
      workers = all_agents |> Enum.reject(&(&1 == planner)) |> Enum.sort()

      agent_lookup =
        Map.new(workers, fn name -> {Atom.to_string(name), name} end)

      {:ok,
       %{
         planner: planner,
         agents: workers,
         agent_lookup: agent_lookup,
         phase: :planning,
         plan: [],
         current_step: nil,
         artifacts: %{},
         replan_count: 0,
         failure_count: 0,
         original_task: nil,
         max_retries_per_step: max_retries,
         max_replans: max_replans,
         max_plan_steps: max_plan_steps,
         parse_plan: parse_plan,
         parse_review: parse_review,
         reviewed_blocked: false
       }}
    end
  end

  @impl true
  def next(%{phase: :planning} = state, context) do
    task = context.original_input.content || ""
    state = %{state | original_task: state.original_task || task}

    prompt =
      if state.replan_count > 0 do
        build_replan_prompt(state)
      else
        build_plan_prompt(state)
      end

    {:next, state.planner, Message.user(prompt), state}
  end

  def next(%{phase: :executing} = state, _context) do
    case find_next_ready_step(state) do
      {:ok, step} ->
        input = build_step_input(step, state)
        state = %{state | current_step: step.id, reviewed_blocked: false}
        {:next, step.assignee, Message.user(input), state}

      :all_done ->
        summary = summarize_artifacts(state)
        {:done, Message.assistant(summary), state}

      {:blocked, failed_step} ->
        if state.reviewed_blocked do
          {:error,
           Error.new(
             :orchestration_error,
             "Plan stalled: all remaining steps are blocked by failed dependencies and recovery was unsuccessful"
           ), state}
        else
          prompt = build_blocked_prompt(state)

          state = %{
            state
            | phase: :reviewing,
              reviewed_blocked: true,
              current_step: failed_step.id
          }

          {:next, state.planner, Message.user(prompt), state}
        end
    end
  end

  def next(%{phase: :reviewing} = state, _context) do
    prompt = build_review_prompt(state)
    {:next, state.planner, Message.user(prompt), state}
  end

  @impl true
  def handle_result(%{phase: :planning} = state, _agent, {:ok, msg}) do
    content = msg.content || ""

    case parse_plan(content, state) do
      {:ok, steps} ->
        case validate_plan(steps, state) do
          :ok ->
            plan =
              Enum.map(steps, fn step ->
                Map.merge(step, %{status: :pending, retry_count: 0, output: nil})
              end)

            {:continue, %{state | phase: :executing, plan: plan}}

          {:error, _} = err ->
            error_from_result(err, state)
        end

      {:error, _} = err ->
        error_from_result(err, state)
    end
  end

  def handle_result(%{phase: :planning} = state, _agent, {:error, err}) do
    {:error, err, state}
  end

  def handle_result(%{phase: :executing} = state, _agent, {:ok, msg}) do
    step = get_step(state, state.current_step)
    content = msg.content

    artifacts =
      Map.put(state.artifacts, step.id, %{message: msg, content: content})

    plan = update_step_status(state.plan, step.id, :completed)

    {:continue,
     %{
       state
       | phase: :reviewing,
         plan: plan,
         artifacts: artifacts,
         reviewed_blocked: false
     }}
  end

  def handle_result(%{phase: :executing} = state, _agent, {:error, _err}) do
    step = get_step(state, state.current_step)
    plan = update_step_status(state.plan, step.id, :failed)
    failure_count = state.failure_count + 1

    {:continue,
     %{
       state
       | phase: :reviewing,
         plan: plan,
         failure_count: failure_count,
         reviewed_blocked: false
     }}
  end

  def handle_result(%{phase: :reviewing} = state, _agent, {:ok, msg}) do
    content = msg.content || ""

    case parse_review(content, state) do
      {:ok, decision} ->
        apply_review_decision(decision, state)

      {:error, _} = err ->
        error_from_result(err, state)
    end
  end

  def handle_result(%{phase: :reviewing} = state, _agent, {:error, err}) do
    {:error, err, state}
  end

  # --- Private: Config validation ---

  defp fetch_planner(config) do
    case Map.fetch(config, :planner_agent) do
      {:ok, planner} when is_atom(planner) ->
        {:ok, planner}

      {:ok, _} ->
        {:error, Error.new(:orchestration_error, ":planner_agent must be an atom")}

      :error ->
        {:error,
         Error.new(
           :orchestration_error,
           "Plan orchestrator requires :planner_agent in config"
         )}
    end
  end

  defp fetch_agents(config, planner) do
    agents = Map.get(config, :agent_names, [])

    if planner in agents do
      {:ok, agents}
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Planner agent #{inspect(planner)} must be in agent_names"
       )}
    end
  end

  defp validate_limit(config, key, default) do
    value = Map.get(config, key, default)

    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error,
       Error.new(
         :orchestration_error,
         "#{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
       )}
    end
  end

  defp validate_parse_plan(nil), do: {:ok, nil}
  defp validate_parse_plan(fun) when is_function(fun, 2), do: {:ok, fun}

  defp validate_parse_plan(_),
    do:
      {:error,
       Error.new(
         :orchestration_error,
         ":parse_plan must be a 2-arity function or nil"
       )}

  defp validate_parse_review(nil), do: {:ok, nil}
  defp validate_parse_review(fun) when is_function(fun, 1), do: {:ok, fun}

  defp validate_parse_review(_),
    do:
      {:error,
       Error.new(
         :orchestration_error,
         ":parse_review must be a 1-arity function or nil"
       )}

  # --- Private: Plan parsing ---

  defp parse_plan(content, state) do
    if state.parse_plan do
      safe_parse(fn -> state.parse_plan.(content, state.agent_lookup) end, :parse_plan)
    else
      parse_plan_response(content, state.agent_lookup)
    end
  end

  defp parse_plan_response(content, agent_lookup) do
    lines = String.split(content, ~r/\r?\n/)

    case extract_plan_block(lines) do
      {:ok, step_lines} ->
        parse_step_lines(step_lines, agent_lookup)

      {:error, _} = err ->
        err
    end
  end

  defp extract_plan_block(lines) do
    lines = Enum.map(lines, &String.trim/1)

    plan_start = Enum.find_index(lines, &(&1 == "PLAN"))
    plan_end = Enum.find_index(lines, &(&1 == "END_PLAN"))

    cond do
      is_nil(plan_start) || is_nil(plan_end) ->
        {:error,
         Error.new(:orchestration_error, "Could not find PLAN/END_PLAN markers in response")}

      plan_end <= plan_start ->
        {:error, Error.new(:orchestration_error, "END_PLAN appears before PLAN marker")}

      true ->
        first = plan_start + 1
        last = plan_end - 1

        step_lines =
          if first > last do
            []
          else
            lines
            |> Enum.slice(first..last)
            |> Enum.reject(&(&1 == ""))
          end

        if step_lines == [] do
          {:error, Error.new(:orchestration_error, "Plan contains no steps")}
        else
          {:ok, step_lines}
        end
    end
  end

  defp parse_step_lines(lines, agent_lookup) do
    results =
      Enum.map(lines, fn line ->
        parse_step_line(line, agent_lookup)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, _} = err -> err
      nil -> {:ok, Enum.map(results, fn {:ok, step} -> step end)}
    end
  end

  defp parse_step_line(line, agent_lookup) do
    case String.split(line, ":", parts: 4) do
      ["STEP", id_str, agent_str, rest] ->
        with {:ok, id} <- parse_step_id(id_str),
             {:ok, agent} <- lookup_agent(String.trim(agent_str), agent_lookup),
             {:ok, description, deps} <- extract_deps(rest) do
          if String.trim(description) == "" do
            {:error, Error.new(:orchestration_error, "Step #{id} has empty description")}
          else
            {:ok,
             %{
               id: id,
               description: String.trim(description),
               assignee: agent,
               deps: deps
             }}
          end
        end

      _ ->
        {:error,
         Error.new(
           :orchestration_error,
           "Invalid STEP format: #{String.slice(line, 0, 80)}"
         )}
    end
  end

  defp parse_step_id(id_str) do
    case Integer.parse(String.trim(id_str)) do
      {id, ""} when id > 0 ->
        {:ok, id}

      _ ->
        {:error, Error.new(:orchestration_error, "Invalid step ID: #{inspect(id_str)}")}
    end
  end

  defp lookup_agent(name_str, agent_lookup) do
    case Map.fetch(agent_lookup, name_str) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         Error.new(
           :orchestration_error,
           "Unknown worker agent: #{inspect(name_str)}",
           %{attempted_worker: name_str, known_workers: Map.keys(agent_lookup)}
         )}
    end
  end

  defp extract_deps(rest) do
    case String.split(rest, ":DEP:") do
      [desc] ->
        {:ok, desc, []}

      [desc | dep_parts] ->
        dep_str = Enum.join(dep_parts, ":DEP:")

        case parse_dep_ids(dep_str) do
          {:ok, deps} -> {:ok, desc, deps}
          {:error, _} = err -> err
        end
    end
  end

  defp parse_dep_ids(dep_str) do
    tokens =
      dep_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    results =
      Enum.map(tokens, fn s ->
        case Integer.parse(s) do
          {id, ""} when id > 0 -> {:ok, id}
          _ -> {:error, s}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, bad_token} ->
        {:error,
         Error.new(
           :orchestration_error,
           "Invalid dependency ID: #{inspect(bad_token)}"
         )}

      nil ->
        {:ok, Enum.map(results, fn {:ok, id} -> id end)}
    end
  end

  # --- Private: Plan validation ---

  defp validate_plan([], _state) do
    {:error, Error.new(:orchestration_error, "Plan contains no steps")}
  end

  defp validate_plan(steps, state) do
    ids = Enum.map(steps, & &1.id)
    id_set = MapSet.new(ids)

    with :ok <- validate_no_duplicates(ids, id_set),
         :ok <- validate_assignees(steps, state),
         :ok <- validate_deps_exist(steps, id_set),
         :ok <- validate_no_self_deps(steps),
         :ok <- validate_no_cycles(steps),
         :ok <- validate_max_steps(steps, state.max_plan_steps) do
      :ok
    end
  end

  defp validate_no_duplicates(ids, id_set) do
    if length(ids) == MapSet.size(id_set) do
      :ok
    else
      dupes = ids -- MapSet.to_list(id_set)

      {:error,
       Error.new(
         :orchestration_error,
         "Plan contains duplicate step IDs: #{inspect(Enum.uniq(dupes))}"
       )}
    end
  end

  defp validate_assignees(steps, state) do
    worker_set = MapSet.new(state.agents)

    invalid =
      Enum.find(steps, fn step -> not MapSet.member?(worker_set, step.assignee) end)

    if is_nil(invalid) do
      :ok
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Step #{invalid.id} assigned to unknown worker: #{inspect(invalid.assignee)}",
         %{assignee: invalid.assignee, known_workers: state.agents}
       )}
    end
  end

  defp validate_deps_exist(steps, id_set) do
    unknown =
      Enum.flat_map(steps, fn step ->
        Enum.reject(step.deps, &MapSet.member?(id_set, &1))
      end)

    if unknown == [] do
      :ok
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Plan references unknown dependency IDs: #{inspect(Enum.uniq(unknown))}"
       )}
    end
  end

  defp validate_no_self_deps(steps) do
    self_dep =
      Enum.find(steps, fn step -> step.id in step.deps end)

    if is_nil(self_dep) do
      :ok
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Step #{self_dep.id} has a self-dependency"
       )}
    end
  end

  defp validate_no_cycles(steps) do
    # Kahn's algorithm for topological sort
    in_degree = Map.new(steps, fn s -> {s.id, length(s.deps)} end)

    queue =
      in_degree
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(fn {id, _} -> id end)

    processed = topo_sort(queue, in_degree, steps, 0)

    if processed == length(steps) do
      :ok
    else
      {:error, Error.new(:orchestration_error, "Plan contains a dependency cycle")}
    end
  end

  defp topo_sort([], _in_degree, _steps, count), do: count

  defp topo_sort([node | rest], in_degree, steps, count) do
    # Find all steps that depend on this node
    dependents =
      Enum.filter(steps, fn s -> node in s.deps end)
      |> Enum.map(& &1.id)

    {new_queue, new_in_degree} =
      Enum.reduce(dependents, {rest, in_degree}, fn dep_id, {q, deg} ->
        new_deg = Map.update!(deg, dep_id, &(&1 - 1))

        if new_deg[dep_id] == 0 do
          {q ++ [dep_id], new_deg}
        else
          {q, new_deg}
        end
      end)

    topo_sort(new_queue, new_in_degree, steps, count + 1)
  end

  defp validate_max_steps(steps, max) do
    if length(steps) <= max do
      :ok
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Plan has #{length(steps)} steps, maximum is #{max}"
       )}
    end
  end

  # --- Private: Review parsing ---

  defp parse_review(content, state) do
    if state.parse_review do
      safe_parse(fn -> state.parse_review.(content) end, :parse_review)
    else
      parse_review_response(content)
    end
  end

  defp parse_review_response(content) do
    lines = String.split(content, ~r/\r?\n/)

    result =
      Enum.find_value(lines, fn line ->
        line = String.trim(line)

        case Regex.run(
               ~r/^REVIEW:(COMPLETE|CONTINUE|RETRY|REASSIGN|REPLAN)(?::(.*))?$/,
               line
             ) do
          [_, action | rest] ->
            payload = List.first(rest)
            {:ok, parse_review_action(action, payload)}

          nil ->
            nil
        end
      end)

    case result do
      {:ok, decision} ->
        {:ok, decision}

      nil ->
        {:error, Error.new(:orchestration_error, "Could not parse review decision from response")}
    end
  end

  defp parse_review_action("COMPLETE", payload),
    do: {:complete, payload || ""}

  defp parse_review_action("CONTINUE", payload),
    do: {:continue, payload || ""}

  defp parse_review_action("RETRY", payload),
    do: {:retry, payload || ""}

  defp parse_review_action("REASSIGN", payload) do
    case String.split(payload || "", ":", parts: 2) do
      [agent, reason] -> {:reassign, String.trim(agent), String.trim(reason)}
      [agent] -> {:reassign, String.trim(agent), ""}
    end
  end

  defp parse_review_action("REPLAN", payload),
    do: {:replan, payload || ""}

  # --- Private: Review decision dispatch ---

  defp apply_review_decision({:complete, summary}, state) do
    final = if summary != "", do: summary, else: summarize_artifacts(state)
    {:done, Message.assistant(final), state}
  end

  defp apply_review_decision({:continue, _reason}, state) do
    {:continue, %{state | phase: :executing}}
  end

  defp apply_review_decision({:retry, _reason}, state) do
    step = get_step(state, state.current_step)

    if step.retry_count < state.max_retries_per_step do
      plan =
        update_step(state.plan, step.id, fn s ->
          %{s | status: :pending, retry_count: s.retry_count + 1}
        end)

      {:continue, %{state | phase: :executing, plan: plan}}
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Step #{step.id} has exhausted retries (#{state.max_retries_per_step})"
       ), state}
    end
  end

  defp apply_review_decision({:reassign, agent_str, _reason}, state) do
    case Map.fetch(state.agent_lookup, agent_str) do
      {:ok, agent_atom} ->
        step = get_step(state, state.current_step)

        plan =
          update_step(state.plan, step.id, fn s ->
            %{s | assignee: agent_atom, status: :pending, retry_count: 0}
          end)

        {:continue, %{state | phase: :executing, plan: plan}}

      :error ->
        {:error,
         Error.new(
           :orchestration_error,
           "REASSIGN to unknown agent: #{inspect(agent_str)}",
           %{attempted_worker: agent_str, known_workers: Map.keys(state.agent_lookup)}
         ), state}
    end
  end

  defp apply_review_decision({:replan, reason}, state) do
    if state.replan_count < state.max_replans do
      new_count = state.replan_count + 1
      events = [%{type: :replan, replan_count: new_count, reason: reason || ""}]

      {:continue,
       %{
         state
         | phase: :planning,
           plan: [],
           current_step: nil,
           replan_count: new_count,
           reviewed_blocked: false
       }, events}
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Replan limit reached (#{state.max_replans})"
       ), state}
    end
  end

  # --- Private: Step resolution ---

  defp find_next_ready_step(state) do
    pending = Enum.filter(state.plan, &(&1.status == :pending))

    if pending == [] do
      :all_done
    else
      ready =
        Enum.find(pending, fn step ->
          Enum.all?(step.deps, fn dep_id ->
            dep = get_step(state, dep_id)
            dep.status == :completed
          end)
        end)

      if ready do
        {:ok, ready}
      else
        # Find the first failed step that is blocking pending steps
        failed_dep_ids =
          pending
          |> Enum.flat_map(fn step ->
            Enum.filter(step.deps, fn dep_id ->
              dep = get_step(state, dep_id)
              dep.status == :failed
            end)
          end)
          |> Enum.uniq()

        failed_step =
          state.plan
          |> Enum.filter(fn s -> s.id in failed_dep_ids end)
          |> Enum.min_by(& &1.id)

        {:blocked, failed_step}
      end
    end
  end

  # --- Private: Prompt builders ---

  defp build_plan_prompt(state) do
    agent_list = Enum.map_join(state.agents, ", ", &Atom.to_string/1)

    """
    You are a project planner. Create a plan to accomplish the following task.

    TASK: #{state.original_task}

    AVAILABLE WORKERS: #{agent_list}

    Create a plan with at most #{state.max_plan_steps} steps. Each step should be assigned to one of the available workers. Steps can depend on previous steps.

    Output your plan in this exact format:
    PLAN
    STEP:1:worker_name:Description of what to do
    STEP:2:worker_name:Description of next task:DEP:1
    END_PLAN

    Use DEP:id to declare dependencies (comma-separated for multiple: DEP:1,2).
    Step IDs must be positive integers. Only assign steps to the listed workers.\
    """
  end

  defp build_replan_prompt(state) do
    agent_list = Enum.map_join(state.agents, ", ", &Atom.to_string/1)

    completed =
      state.artifacts
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map_join("\n", fn {id, artifact} ->
        "  Step #{id}: #{artifact.content || "(no output)"}"
      end)

    completed_section =
      if completed != "" do
        "\n\nCOMPLETED WORK SO FAR:\n#{completed}"
      else
        ""
      end

    """
    You are a project planner. The previous plan did not succeed and needs replanning.

    TASK: #{state.original_task}

    AVAILABLE WORKERS: #{agent_list}#{completed_section}

    Create a new plan with at most #{state.max_plan_steps} steps. Each step should be assigned to one of the available workers.

    Output your plan in this exact format:
    PLAN
    STEP:1:worker_name:Description of what to do
    STEP:2:worker_name:Description of next task:DEP:1
    END_PLAN

    Use DEP:id to declare dependencies (comma-separated for multiple: DEP:1,2).
    Step IDs must be positive integers. Only assign steps to the listed workers.\
    """
  end

  defp build_step_input(step, state) do
    dep_context =
      step.deps
      |> Enum.sort()
      |> Enum.map(fn dep_id ->
        case Map.get(state.artifacts, dep_id) do
          %{content: content} when not is_nil(content) ->
            "Result from step #{dep_id}: #{content}"

          _ ->
            "Result from step #{dep_id}: (no output)"
        end
      end)
      |> Enum.join("\n\n")

    if dep_context == "" do
      "TASK: #{step.description}"
    else
      "TASK: #{step.description}\n\nCONTEXT:\n#{dep_context}"
    end
  end

  defp build_review_prompt(state) do
    step = get_step(state, state.current_step)
    artifact = Map.get(state.artifacts, step.id)

    step_output =
      cond do
        artifact && artifact.content ->
          "OUTPUT: #{artifact.content}"

        step.status == :failed ->
          "OUTPUT: Step failed"

        true ->
          "OUTPUT: (no output)"
      end

    plan_summary = build_plan_summary(state)

    """
    Review the result of the latest step and decide how to proceed.

    STEP #{step.id}: #{step.description} (assigned to: #{step.assignee})
    STATUS: #{step.status}
    #{step_output}

    #{plan_summary}

    Respond with exactly one of:
    REVIEW:COMPLETE:summary of final result
    REVIEW:CONTINUE:reason to continue to next step
    REVIEW:RETRY:reason to retry this step
    REVIEW:REASSIGN:worker_name:reason to reassign to different worker
    REVIEW:REPLAN:reason to create a new plan\
    """
  end

  defp build_blocked_prompt(state) do
    failed_steps =
      state.plan
      |> Enum.filter(&(&1.status == :failed))
      |> Enum.map_join(", ", fn s -> "step #{s.id} (#{s.description})" end)

    blocked_steps =
      state.plan
      |> Enum.filter(&(&1.status == :pending))
      |> Enum.map_join(", ", fn s -> "step #{s.id} (#{s.description})" end)

    plan_summary = build_plan_summary(state)

    """
    The plan is blocked. Some steps have failed and their dependent steps cannot proceed.

    FAILED STEPS: #{failed_steps}
    BLOCKED STEPS: #{blocked_steps}

    #{plan_summary}

    You can recover by retrying or reassigning the failed steps, or create a new plan.

    Respond with exactly one of:
    REVIEW:RETRY:reason to retry the failed step
    REVIEW:REASSIGN:worker_name:reason to reassign to different worker
    REVIEW:REPLAN:reason to create a new plan\
    """
  end

  defp build_plan_summary(state) do
    status_lines =
      state.plan
      |> Enum.map(fn step ->
        deps = if step.deps == [], do: "none", else: Enum.map_join(step.deps, ",", &to_string/1)
        "  Step #{step.id} [#{step.status}] #{step.assignee}: #{step.description} (deps: #{deps})"
      end)
      |> Enum.join("\n")

    "PLAN STATUS:\n#{status_lines}"
  end

  defp summarize_artifacts(state) do
    state.plan
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.sort_by(& &1.id)
    |> Enum.map_join("\n\n", fn step ->
      artifact = Map.get(state.artifacts, step.id)
      content = if artifact, do: artifact.content || "(no output)", else: "(no output)"
      "Step #{step.id} (#{step.description}): #{content}"
    end)
  end

  # --- Private: Safe parser wrappers ---

  defp safe_parse(parse_fn, parser_name) do
    result = parse_fn.()
    validate_parse_result(result, parser_name)
  catch
    kind, reason ->
      {:error,
       Error.new(
         :orchestration_error,
         "Custom #{parser_name} crashed: #{format_crash(kind, reason)}"
       )}
  end

  defp validate_parse_result({:ok, steps}, :parse_plan) when is_list(steps) do
    case validate_step_shapes(steps) do
      :ok -> {:ok, steps}
      {:error, _} = err -> err
    end
  end

  defp validate_parse_result({:ok, decision}, :parse_review) when is_tuple(decision) do
    case validate_review_shape(decision) do
      :ok -> {:ok, decision}
      {:error, _} = err -> err
    end
  end

  defp validate_parse_result({:error, %Error{}} = result, _name), do: result

  defp validate_parse_result(other, name) do
    {:error,
     Error.new(
       :orchestration_error,
       "Custom #{name} returned invalid shape: #{inspect(other)}"
     )}
  end

  defp validate_step_shapes([]), do: :ok

  defp validate_step_shapes([step | rest]) do
    cond do
      not is_map(step) ->
        {:error,
         Error.new(:orchestration_error, "Custom parse_plan step is not a map: #{inspect(step)}")}

      not (is_integer(step[:id]) and step[:id] > 0) ->
        {:error,
         Error.new(
           :orchestration_error,
           "Custom parse_plan step has invalid :id: #{inspect(step[:id])}"
         )}

      not is_binary(step[:description]) ->
        {:error,
         Error.new(
           :orchestration_error,
           "Custom parse_plan step has invalid :description: #{inspect(step[:description])}"
         )}

      not is_atom(step[:assignee]) ->
        {:error,
         Error.new(
           :orchestration_error,
           "Custom parse_plan step has invalid :assignee: #{inspect(step[:assignee])}"
         )}

      not is_list(step[:deps]) ->
        {:error,
         Error.new(
           :orchestration_error,
           "Custom parse_plan step has invalid :deps: #{inspect(step[:deps])}"
         )}

      true ->
        validate_step_shapes(rest)
    end
  end

  @valid_review_shapes [:complete, :continue, :retry, :replan]

  defp validate_review_shape({action, _payload}) when action in @valid_review_shapes, do: :ok
  defp validate_review_shape({:reassign, agent, _reason}) when is_binary(agent), do: :ok

  defp validate_review_shape(other) do
    {:error,
     Error.new(
       :orchestration_error,
       "Custom parse_review returned invalid decision shape: #{inspect(other)}"
     )}
  end

  defp format_crash(:error, %{__exception__: true} = exception),
    do: Exception.message(exception)

  defp format_crash(:error, reason), do: inspect(reason)
  defp format_crash(:exit, reason), do: "exit: #{inspect(reason)}"
  defp format_crash(:throw, value), do: "throw: #{inspect(value)}"

  # --- Private: Error helpers ---

  defp error_from_result({:error, error}, state) do
    {:error, error, state}
  end

  # --- Private: Plan manipulation ---

  defp get_step(state, id) do
    Enum.find(state.plan, fn s -> s.id == id end)
  end

  defp update_step_status(plan, id, status) do
    update_step(plan, id, fn s -> %{s | status: status} end)
  end

  defp update_step(plan, id, update_fn) do
    Enum.map(plan, fn s ->
      if s.id == id, do: update_fn.(s), else: s
    end)
  end
end
