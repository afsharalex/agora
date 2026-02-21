defmodule Agora.Orchestrator.Runner do
  @moduledoc """
  GenServer that drives the orchestration loop for multi-agent coordination.

  Mirrors the `Agora.Agent` pattern: synchronous `run/2` blocks until the
  orchestration completes, with crash protection via try/catch.

  ## Options

    * `:orchestrator` (required) — module implementing `Agora.Orchestrator`
    * `:agents` (required) — `%{atom() => AgentConfig.t()}` map of agent configs
    * `:orchestrator_opts` (optional) — keyword list merged into orchestrator init config
    * `:termination` (optional) — a termination condition function
    * `:max_turns` (optional, default `100`) — hard safety limit
    * `:name` (optional) — GenServer name registration
    * `:cancel_token` (optional) — `%CancelToken{}` for cooperative cancellation
    * `:context_policy` (optional) — `%ContextPolicy{}` for message compaction
    * `:telemetry_metadata` (optional) — `map()` merged into telemetry event metadata

  ## Run Scope

  Each `run/2` call re-initializes the orchestrator state and clears history.
  Agent processes persist across runs — they keep their conversation history.

  ## Example

      agents = %{
        helper: AgentConfig.new!(provider: :echo, model: "echo")
      }

      {:ok, pid} = Runner.start_link(
        orchestrator: Agora.Orchestrator.Single,
        agents: agents
      )

      {:ok, response} = Runner.run(pid, "Hello!")

  """

  use GenServer

  alias Agora.{Agent, CancelToken, Error, Message}

  @default_max_turns 100

  @doc """
  Starts a Runner process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {server_opts, runner_opts} = extract_server_opts(opts)
    GenServer.start_link(__MODULE__, runner_opts, server_opts)
  end

  @doc """
  Sends a message to the orchestrator and returns the final result.

  Accepts a string (converted to a user message) or a `%Message{}` struct.
  Blocks until the orchestration completes.
  """
  @spec run(GenServer.server(), String.t() | Message.t()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def run(runner, input) when is_binary(input) do
    run(runner, Message.user(input))
  end

  def run(runner, %Message{} = message) do
    GenServer.call(runner, {:run, message}, :infinity)
  end

  @doc """
  Returns the orchestration history from the last run.
  """
  @spec get_history(GenServer.server()) :: [Agora.Orchestrator.turn()]
  def get_history(runner) do
    GenServer.call(runner, :get_history)
  end

  @doc """
  Returns the current runner status.

  Note: like `Agent.get_status/1`, this always returns `:idle` due to
  synchronous call serialization (calls queue behind any active run).
  """
  @spec get_status(GenServer.server()) :: :idle | :running
  def get_status(runner) do
    GenServer.call(runner, :get_status)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    with {:ok, validated} <- validate_opts(opts) do
      do_init(validated)
    else
      {:error, error} -> {:stop, error}
    end
  end

  defp validate_opts(opts) do
    with {:ok, orchestrator} <- fetch_required(opts, :orchestrator),
         :ok <- validate_orchestrator(orchestrator),
         {:ok, agents} <- fetch_required(opts, :agents),
         :ok <- validate_agents_map(agents),
         :ok <- validate_orchestrator_opts(Keyword.get(opts, :orchestrator_opts, [])),
         :ok <- validate_termination(Keyword.get(opts, :termination)),
         :ok <- validate_max_turns(Keyword.get(opts, :max_turns, @default_max_turns)),
         :ok <- validate_cancel_token(Keyword.get(opts, :cancel_token)),
         :ok <- validate_context_policy(Keyword.get(opts, :context_policy)),
         :ok <- validate_telemetry_metadata(Keyword.get(opts, :telemetry_metadata, %{})) do
      {:ok,
       %{
         orchestrator: orchestrator,
         agents: agents,
         orchestrator_opts: Keyword.get(opts, :orchestrator_opts, []),
         termination: Keyword.get(opts, :termination),
         max_turns: Keyword.get(opts, :max_turns, @default_max_turns),
         runner_name: Keyword.get(opts, :runner_name),
         cancel_token: Keyword.get(opts, :cancel_token),
         context_policy: Keyword.get(opts, :context_policy),
         telemetry_metadata: Keyword.get(opts, :telemetry_metadata, %{})
       }}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         Error.new(:config_error, "Missing required option: #{inspect(key)}", %{option: key})}
    end
  end

  defp validate_agents_map(agents) when is_map(agents) do
    invalid =
      Enum.reject(agents, fn {_name, config} ->
        match?(%Agora.AgentConfig{}, config)
      end)

    case invalid do
      [] ->
        :ok

      [{name, _} | _] ->
        {:error,
         Error.new(
           :config_error,
           "Agent #{inspect(name)} config must be an %AgentConfig{} struct"
         )}
    end
  end

  defp validate_agents_map(_),
    do:
      {:error, Error.new(:config_error, ":agents must be a map of %{atom() => AgentConfig.t()}")}

  defp validate_termination(nil), do: :ok
  defp validate_termination(fun) when is_function(fun, 1), do: :ok

  defp validate_termination(_),
    do: {:error, Error.new(:config_error, ":termination must be a 1-arity function or nil")}

  defp validate_orchestrator(mod) when is_atom(mod), do: :ok

  defp validate_orchestrator(_),
    do: {:error, Error.new(:config_error, ":orchestrator must be a module atom")}

  defp validate_orchestrator_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, Error.new(:config_error, ":orchestrator_opts must be a keyword list")}
    end
  end

  defp validate_orchestrator_opts(_),
    do: {:error, Error.new(:config_error, ":orchestrator_opts must be a keyword list")}

  defp validate_max_turns(n) when is_integer(n) and n > 0, do: :ok

  defp validate_max_turns(_),
    do: {:error, Error.new(:config_error, ":max_turns must be a positive integer")}

  defp validate_cancel_token(nil), do: :ok
  defp validate_cancel_token(%CancelToken{}), do: :ok

  defp validate_cancel_token(_),
    do: {:error, Error.new(:config_error, ":cancel_token must be a %CancelToken{} or nil")}

  defp validate_context_policy(nil), do: :ok
  defp validate_context_policy(%Agora.ContextPolicy{}), do: :ok

  defp validate_context_policy(_),
    do: {:error, Error.new(:config_error, ":context_policy must be a %ContextPolicy{} or nil")}

  defp validate_telemetry_metadata(meta) when is_map(meta), do: :ok

  defp validate_telemetry_metadata(_),
    do: {:error, Error.new(:config_error, ":telemetry_metadata must be a map")}

  defp do_init(validated) do
    %{
      orchestrator: orchestrator,
      agents: agents,
      orchestrator_opts: orchestrator_opts,
      termination: termination,
      max_turns: max_turns,
      runner_name: runner_name,
      cancel_token: cancel_token,
      context_policy: context_policy,
      telemetry_metadata: telemetry_metadata
    } = validated

    case start_agents(agents) do
      {:ok, agent_pids} ->
        orch_config = build_orch_config(agents, orchestrator_opts)

        case safe_orchestrator_init(orchestrator, orch_config) do
          {:ok, orch_state} ->
            {:ok,
             %{
               orchestrator: orchestrator,
               orchestrator_state: orch_state,
               orchestrator_opts: orchestrator_opts,
               agents: agents,
               agent_pids: agent_pids,
               history: [],
               termination: termination,
               max_turns: max_turns,
               status: :idle,
               runner_name: runner_name,
               cancel_token: cancel_token,
               context_policy: context_policy,
               telemetry_metadata: telemetry_metadata
             }}

          {:error, error} ->
            stop_all_agents(agent_pids)
            {:stop, error}
        end

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:run, %Message{} = input}, _from, state) do
    state = %{state | status: :running}
    telemetry_meta = telemetry_metadata(state)

    :telemetry.execute(
      [:agora, :orchestrator, :run, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    start_time = System.monotonic_time()

    # D10: Re-initialize orchestrator state and clear history per run
    orch_config = build_orch_config(state.agents, state.orchestrator_opts)

    {result, state} =
      case safe_orchestrator_init(state.orchestrator, orch_config) do
        {:ok, orch_state} ->
          state = %{state | orchestrator_state: orch_state, history: []}
          safe_orchestration_loop(input, state)

        {:error, error} ->
          {{:error, error}, state}
      end

    duration = System.monotonic_time() - start_time
    state = %{state | status: :idle}

    run_stop_meta =
      case result do
        {:ok, _} ->
          Map.put(telemetry_meta, :steps, length(state.history))

        {:error, error} ->
          telemetry_meta |> Map.put(:steps, length(state.history)) |> Map.put(:error, error)
      end

    :telemetry.execute(
      [:agora, :orchestrator, :run, :stop],
      %{duration: duration, steps: length(state.history)},
      run_stop_meta
    )

    {:reply, result, state}
  end

  def handle_call(:get_history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_all_agents(state.agent_pids)
    :ok
  end

  # --- Private: Safe wrappers ---

  defp safe_orchestrator_init(orchestrator, orch_config) do
    orchestrator.init(orch_config)
  catch
    kind, reason ->
      {:error,
       Error.new(
         :orchestration_error,
         "Orchestrator init crashed: #{format_crash(kind, reason)}",
         %{kind: to_string(kind), reason: format_crash_reason(reason)}
       )}
  end

  defp safe_orchestration_loop(input, state) do
    orchestration_loop(input, 0, state)
  catch
    kind, reason ->
      error =
        Error.new(
          :orchestration_error,
          format_crash(kind, reason),
          %{kind: to_string(kind), reason: format_crash_reason(reason)}
        )

      {{:error, error}, state}
  end

  # --- Private: Orchestration loop ---

  defp orchestration_loop(input, turn, state) do
    %{
      orchestrator: orchestrator,
      orchestrator_state: orch_state,
      termination: termination,
      max_turns: max_turns,
      history: history,
      cancel_token: cancel_token
    } = state

    # Check cancellation before anything else
    if cancel_token && CancelToken.cancelled?(cancel_token) do
      {{:error, Error.new(:cancelled, "Execution cancelled")}, state}
    else
      context = %{original_input: input, history: history}

      # Check termination condition first — a valid termination at the boundary
      # should succeed rather than being preempted by the hard safety limit.
      case check_termination(termination, context) do
        {:done, msg} ->
          {{:ok, msg}, state}

        :continue ->
          # Check max_turns safety limit after termination
          if turn >= max_turns do
            error =
              Error.new(
                :orchestration_error,
                "Reached maximum turns (#{max_turns})",
                %{max_turns: max_turns, turns: turn}
              )

            {{:error, error}, state}
          else
            # Ask orchestrator what to do next
            case orchestrator.next(orch_state, context) do
              {:done, result, new_orch_state} ->
                {{:ok, result}, %{state | orchestrator_state: new_orch_state}}

              {:next, agent_name, input_msg, new_orch_state} ->
                state = %{state | orchestrator_state: new_orch_state}
                run_agent_step(input, turn, agent_name, input_msg, state)
            end
          end
      end
    end
  end

  defp run_agent_step(original_input, turn, agent_name, input_msg, state) do
    %{
      orchestrator: orchestrator,
      orchestrator_state: orch_state,
      agent_pids: agent_pids
    } = state

    case Map.fetch(agent_pids, agent_name) do
      {:ok, pid} ->
        step_meta = step_metadata(state, agent_name, turn)

        :telemetry.execute(
          [:agora, :orchestrator, :step, :start],
          %{system_time: System.system_time()},
          step_meta
        )

        step_start = System.monotonic_time()
        result = safe_agent_run(pid, agent_name, input_msg)

        :telemetry.execute(
          [:agora, :orchestrator, :step, :stop],
          %{duration: System.monotonic_time() - step_start},
          step_meta
        )

        # Append turn to history
        turn_record = %{agent: agent_name, input: input_msg, output: result}
        history = state.history ++ [turn_record]
        state = %{state | history: history}

        # Let orchestrator handle the result
        case orchestrator.handle_result(orch_state, agent_name, result) do
          {:continue, new_orch_state} ->
            state = %{state | orchestrator_state: new_orch_state}
            orchestration_loop(original_input, turn + 1, state)

          {:done, result_msg, new_orch_state} ->
            {{:ok, result_msg}, %{state | orchestrator_state: new_orch_state}}

          {:error, error, new_orch_state} ->
            {{:error, error}, %{state | orchestrator_state: new_orch_state}}
        end

      :error ->
        error =
          Error.new(
            :orchestration_error,
            "Unknown agent: #{inspect(agent_name)}",
            %{agent: agent_name, known_agents: Map.keys(agent_pids)}
          )

        {{:error, error}, state}
    end
  end

  defp safe_agent_run(pid, agent_name, input_msg) do
    Agent.run(pid, input_msg)
  catch
    kind, reason ->
      {:error,
       Error.new(
         :orchestration_error,
         "Agent #{inspect(agent_name)} is unavailable: #{format_crash(kind, reason)}",
         %{agent: agent_name, kind: to_string(kind)}
       )}
  end

  defp check_termination(nil, _context), do: :continue
  defp check_termination(condition, context), do: condition.(context)

  # --- Private: Agent lifecycle (D5, D13) ---

  defp start_agents(agents) do
    start_agents(Map.to_list(agents), %{})
  end

  defp start_agents([], acc), do: {:ok, acc}

  defp start_agents([{name, config} | rest], acc) do
    case Agora.Agent.Supervisor.start_agent(config) do
      {:ok, pid} ->
        start_agents(rest, Map.put(acc, name, pid))

      {:error, reason} ->
        # D13: Stop already-started agents on failure
        stop_all_agents(acc)

        error =
          Error.new(
            :orchestration_error,
            "Failed to start agent #{inspect(name)}: #{inspect(reason)}",
            %{agent: name}
          )

        {:error, error}
    end
  end

  defp stop_all_agents(agent_pids) do
    Enum.each(agent_pids, fn {_name, pid} ->
      Agora.Agent.Supervisor.stop_agent(pid)
    end)
  end

  defp build_orch_config(agents, orchestrator_opts) do
    user_opts =
      orchestrator_opts
      |> Map.new()
      |> Map.delete(:agent_names)

    Map.merge(%{agent_names: Map.keys(agents)}, user_opts)
  end

  # --- Private: Server opts extraction ---

  defp extract_server_opts(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    server_opts = if name, do: [name: name], else: []
    runner_name = if is_atom(name), do: Atom.to_string(name), else: nil
    opts = Keyword.put(opts, :runner_name, runner_name)

    {server_opts, opts}
  end

  # --- Private: Telemetry ---

  defp telemetry_metadata(state) do
    base = %{
      orchestrator: state.orchestrator,
      name: state.runner_name
    }

    Map.merge(state.telemetry_metadata, base)
  end

  defp step_metadata(state, agent_name, step) do
    base = %{
      orchestrator: state.orchestrator,
      agent: agent_name,
      step: step
    }

    Map.merge(state.telemetry_metadata, base)
  end

  # --- Private: Crash formatting ---

  defp format_crash(:error, %{__exception__: true} = exception) do
    "Orchestration loop crashed: " <> Exception.message(exception)
  end

  defp format_crash(:error, reason) do
    "Orchestration loop crashed: " <> inspect(reason)
  end

  defp format_crash(:exit, reason) do
    "Orchestration loop exited: " <> inspect(reason)
  end

  defp format_crash(:throw, value) do
    "Orchestration loop threw: " <> inspect(value)
  end

  defp format_crash_reason(%{__exception__: true} = exception) do
    Exception.message(exception)
  end

  defp format_crash_reason(reason) do
    inspect(reason)
  end
end
