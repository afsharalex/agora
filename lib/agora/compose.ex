defmodule Agora.Compose do
  @moduledoc """
  Agent-first composition functions for multi-agent coordination.

  All functions accept a keyword list of `{atom, AgentConfig.t()}` as the
  agent reference model. This compiles to the appropriate substrate
  (workflow or orchestrator) while preserving all cross-cutting behavior
  (cancel tokens, context policies, telemetry metadata).

  ## Workflow-Backed Patterns

    * `sequential/3` — pipeline: each agent runs once, gets prior output
    * `parallel/3` — independent: agents run concurrently

  ## Orchestrator-Backed Patterns

    * `round_robin/3` — agents take turns in conversation
    * `group_chat/3` — shared transcript, all see all
    * `supervisor/4` — manager delegates to workers
    * `plan/4` — planner manages staged execution
    * `handoff/3` — agents pass control to each other
  """

  alias Agora.{AgentConfig, Error, Execution}

  # --- Workflow-backed patterns ---

  @doc """
  Runs agents in sequence, each building on the previous result.

  Each agent receives the content of the previous agent's response as input.
  The first agent receives the original `input` string.

  Returns `{:ok, map()}` where map keys are agent names and values are step results.

  ## Examples

      {:ok, results} = Agora.sequential("Write about Elixir", [
        researcher: researcher_config,
        writer: writer_config
      ])

  """
  @spec sequential(String.t(), keyword(AgentConfig.t()), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def sequential(input, agents, opts \\ [])

  def sequential(input, agents, opts) when is_binary(input) do
    with {:ok, agents} <- validate_agents(agents),
         {:ok, opts} <- validate_opts(opts) do
      step_specs = agents_to_sequential_steps(agents, input)
      Execution.run_workflow(:sequential, step_specs, opts)
    end
  end

  def sequential(input, _agents, _opts) when not is_binary(input) do
    Error.wrap(:config_error, "sequential/3 expects a binary input, got: #{inspect(input)}")
  end

  @doc """
  Runs agents concurrently and independently.

  Each agent receives the original `input` string. Results are collected
  into a map keyed by agent name.

  Returns `{:ok, map()}` where map keys are agent names and values are step results.

  ## Examples

      {:ok, results} = Agora.parallel("Analyze this data", [
        sentiment: sentiment_config,
        summary: summary_config,
        keywords: keywords_config
      ])

  """
  @spec parallel(String.t(), keyword(AgentConfig.t()), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def parallel(input, agents, opts \\ [])

  def parallel(input, agents, opts) when is_binary(input) do
    with {:ok, agents} <- validate_agents(agents),
         {:ok, opts} <- validate_opts(opts) do
      step_specs = agents_to_parallel_steps(agents, input)
      Execution.run_workflow(:parallel, step_specs, opts)
    end
  end

  def parallel(input, _agents, _opts) when not is_binary(input) do
    Error.wrap(:config_error, "parallel/3 expects a binary input, got: #{inspect(input)}")
  end

  # --- Orchestrator-backed patterns ---

  @doc """
  Agents take turns in round-robin order through a multi-turn conversation.

  Returns `{:ok, Message.t()}` — the final message from the orchestration.

  ## Examples

      {:ok, response} = Agora.round_robin("Debate the topic", [
        advocate: advocate_config,
        critic: critic_config
      ], termination: TerminationCondition.max_turns(6))

  """
  @spec round_robin(String.t(), keyword(AgentConfig.t()), keyword()) ::
          {:ok, Agora.Message.t()} | {:error, Error.t()}
  def round_robin(input, agents, opts \\ []) do
    with {:ok, agents} <- validate_agents(agents),
         {:ok, opts} <- validate_opts(opts),
         :ok <- validate_input(input, "round_robin/3") do
      agents_map = Map.new(agents)
      exec_opts = Keyword.merge(opts, agents: agents_map)
      Execution.run(:round_robin, input, exec_opts)
    end
  end

  @doc """
  Agents collaborate in a shared transcript where all see all messages.

  Returns `{:ok, Message.t()}` — the final message from the orchestration.

  ## Examples

      {:ok, response} = Agora.group_chat("Plan the project", [
        architect: architect_config,
        developer: developer_config,
        tester: tester_config
      ])

  """
  @spec group_chat(String.t(), keyword(AgentConfig.t()), keyword()) ::
          {:ok, Agora.Message.t()} | {:error, Error.t()}
  def group_chat(input, agents, opts \\ []) do
    with {:ok, agents} <- validate_agents(agents),
         {:ok, opts} <- validate_opts(opts),
         :ok <- validate_input(input, "group_chat/3") do
      agents_map = Map.new(agents)
      exec_opts = Keyword.merge(opts, agents: agents_map)
      Execution.run(:group_chat, input, exec_opts)
    end
  end

  @doc """
  A supervisor agent delegates tasks to worker agents.

  The second argument is a `{name, config}` tuple identifying the supervisor agent.
  Workers are provided as the usual keyword list.

  Returns `{:ok, Message.t()}` — the final message from the orchestration.

  ## Examples

      {:ok, response} = Agora.supervisor("Complete the task",
        {:manager, manager_config},
        [worker_a: worker_a_config, worker_b: worker_b_config]
      )

  """
  @spec supervisor(String.t(), {atom(), AgentConfig.t()}, keyword(AgentConfig.t()), keyword()) ::
          {:ok, Agora.Message.t()} | {:error, Error.t()}
  def supervisor(input, leader, workers, opts \\ [])

  def supervisor(input, {sup_name, sup_config}, workers, opts)
      when is_atom(sup_name) do
    with {:ok, _} <- validate_agents([{sup_name, sup_config} | workers]),
         {:ok, opts} <- validate_opts(opts),
         :ok <- validate_input(input, "supervisor/4"),
         {:ok, user_orch_opts} <- validate_orchestrator_opts(opts) do
      agents_map = Map.new([{sup_name, sup_config} | workers])
      merged_orch_opts = Keyword.merge(user_orch_opts, supervisor_agent: sup_name)
      exec_opts = Keyword.merge(opts, agents: agents_map, orchestrator_opts: merged_orch_opts)
      Execution.run(:supervisor, input, exec_opts)
    end
  end

  def supervisor(_input, bad_leader, _workers, _opts) do
    Error.wrap(
      :config_error,
      "supervisor/4 expects {atom, %AgentConfig{}} as second argument, got: #{inspect(bad_leader)}"
    )
  end

  @doc """
  A planner agent creates and manages a plan executed by worker agents.

  The second argument is a `{name, config}` tuple identifying the planner agent.
  Workers are provided as the usual keyword list.

  Returns `{:ok, Message.t()}` — the final message from the orchestration.

  ## Examples

      {:ok, response} = Agora.plan("Build the feature",
        {:planner, planner_config},
        [coder: coder_config, reviewer: reviewer_config]
      )

  """
  @spec plan(String.t(), {atom(), AgentConfig.t()}, keyword(AgentConfig.t()), keyword()) ::
          {:ok, Agora.Message.t()} | {:error, Error.t()}
  def plan(input, planner, workers, opts \\ [])

  def plan(input, {planner_name, planner_config}, workers, opts)
      when is_atom(planner_name) do
    with {:ok, _} <- validate_agents([{planner_name, planner_config} | workers]),
         {:ok, opts} <- validate_opts(opts),
         :ok <- validate_input(input, "plan/4"),
         {:ok, user_orch_opts} <- validate_orchestrator_opts(opts) do
      agents_map = Map.new([{planner_name, planner_config} | workers])
      merged_orch_opts = Keyword.merge(user_orch_opts, planner_agent: planner_name)
      exec_opts = Keyword.merge(opts, agents: agents_map, orchestrator_opts: merged_orch_opts)
      Execution.run(:plan, input, exec_opts)
    end
  end

  def plan(_input, bad_planner, _workers, _opts) do
    Error.wrap(
      :config_error,
      "plan/4 expects {atom, %AgentConfig{}} as second argument, got: #{inspect(bad_planner)}"
    )
  end

  @doc """
  Agents pass control to each other in a decentralized fashion.

  The first agent in the list runs first by default, unless `:initial` is specified.

  Returns `{:ok, Message.t()}` — the final message from the orchestration.

  ## Options

    * `:initial` — atom name of the agent to start with (default: first in list)
    * All other orchestrator options (`:termination`, `:max_turns`, etc.)

  ## Examples

      {:ok, response} = Agora.handoff("Route this request", [
        triage: triage_config,
        billing: billing_config,
        support: support_config
      ])

  """
  @spec handoff(String.t(), keyword(AgentConfig.t()), keyword()) ::
          {:ok, Agora.Message.t()} | {:error, Error.t()}
  def handoff(input, agents, opts \\ []) do
    with {:ok, agents} <- validate_agents(agents),
         {:ok, opts} <- validate_opts(opts),
         :ok <- validate_input(input, "handoff/3"),
         {:ok, user_orch_opts} <- validate_orchestrator_opts(opts) do
      agents_map = Map.new(agents)
      {initial, rest_opts} = Keyword.pop(opts, :initial)
      # safe: validate_agents ensures non-empty
      initial = initial || elem(hd(agents), 0)
      merged_orch_opts = Keyword.merge(user_orch_opts, initial_agent: initial)

      exec_opts =
        Keyword.merge(rest_opts, agents: agents_map, orchestrator_opts: merged_orch_opts)

      Execution.run(:handoff, input, exec_opts)
    end
  end

  # --- Validation ---

  @doc false
  @spec validate_agents(keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def validate_agents(agents) do
    cond do
      not Keyword.keyword?(agents) ->
        Error.wrap(:config_error, "agents must be a keyword list of {atom, %AgentConfig{}}")

      agents == [] ->
        Error.wrap(:config_error, "agents list must not be empty")

      has_duplicate_keys?(agents) ->
        Error.wrap(
          :config_error,
          "agents list has duplicate keys: #{inspect(duplicate_keys(agents))}"
        )

      not Enum.all?(agents, fn {_k, v} -> match?(%AgentConfig{}, v) end) ->
        Error.wrap(:config_error, "all agent values must be %AgentConfig{} structs")

      true ->
        {:ok, agents}
    end
  end

  defp validate_opts(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      Error.wrap(:config_error, "opts must be a keyword list, got: #{inspect(opts)}")
    end
  end

  defp validate_input(input, _fn_name) when is_binary(input), do: :ok

  defp validate_input(input, fn_name) do
    Error.wrap(:config_error, "#{fn_name} expects a binary input, got: #{inspect(input)}")
  end

  defp validate_orchestrator_opts(opts) do
    user_orch_opts = Keyword.get(opts, :orchestrator_opts, [])

    if Keyword.keyword?(user_orch_opts) do
      {:ok, user_orch_opts}
    else
      Error.wrap(
        :config_error,
        "orchestrator_opts must be a keyword list, got: #{inspect(user_orch_opts)}"
      )
    end
  end

  # --- Private: Step construction ---

  defp agents_to_sequential_steps(agents, input) do
    agent_names = Keyword.keys(agents)

    agents
    |> Enum.with_index()
    |> Enum.map(fn {{name, config}, index} ->
      mapper =
        if index == 0 do
          fn _results -> input end
        else
          prev_name = Enum.at(agent_names, index - 1)

          fn results ->
            case results[prev_name] do
              {:ok, %Agora.Message{content: content}} when is_binary(content) -> content
              {:ok, %Agora.Message{}} -> ""
              %Agora.Message{content: content} when is_binary(content) -> content
              %Agora.Message{} -> ""
              {:ok, other} when is_binary(other) -> other
              other when is_binary(other) -> other
              _ -> ""
            end
          end
        end

      {name, config, input_mapper: mapper}
    end)
  end

  defp agents_to_parallel_steps(agents, input) do
    Enum.map(agents, fn {name, config} ->
      mapper = fn _results -> input end
      {name, config, input_mapper: mapper}
    end)
  end

  # --- Private: Key validation helpers ---

  defp has_duplicate_keys?(kw) do
    keys = Keyword.keys(kw)
    length(keys) != length(Enum.uniq(keys))
  end

  defp duplicate_keys(kw) do
    keys = Keyword.keys(kw)

    keys
    |> Enum.frequencies()
    |> Enum.filter(fn {_k, count} -> count > 1 end)
    |> Enum.map(fn {k, _} -> k end)
  end
end
