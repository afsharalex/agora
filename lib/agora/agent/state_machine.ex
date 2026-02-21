defmodule Agora.Agent.StateMachine do
  @moduledoc false

  # gen_statem backend for lifecycle-enabled agents.
  # Uses :handle_event_function callback mode with :state_enter for
  # lifecycle state management (on_enter/on_exit hooks, state timeouts).

  @behaviour :gen_statem

  require Logger

  alias Agora.{AgentConfig, Error, Memory, Message, StreamEvent}
  alias Agora.Agent.{Lifecycle, Loop, StreamLoop}
  alias Agora.Agent.Lifecycle.StateConfig

  @messages_key :agora_agent_sm_messages
  @run_start_key :agora_agent_sm_run_start

  @spec start_link(AgentConfig.t(), keyword()) :: GenServer.on_start()
  def start_link(%AgentConfig{} = config, server_opts) do
    {name, statem_opts} = Keyword.pop(server_opts, :name)
    # Pass through supported gen_statem options (e.g., :spawn_opt, :hibernate_after)
    opts = Keyword.take(statem_opts, [:spawn_opt, :hibernate_after])

    case name do
      nil ->
        :gen_statem.start_link(__MODULE__, config, opts)

      name when is_atom(name) ->
        :gen_statem.start_link({:local, name}, __MODULE__, config, opts)

      {:global, _} = name ->
        :gen_statem.start_link(name, __MODULE__, config, opts)

      {:via, _, _} = name ->
        :gen_statem.start_link(name, __MODULE__, config, opts)
    end
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)
    restart = if config.memory, do: :transient, else: :temporary

    %{
      id: Agora.Agent,
      start: {Agora.Agent, :start_link, [opts]},
      restart: restart
    }
  end

  # --- gen_statem callbacks ---

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(%AgentConfig{} = config) do
    lifecycle = config.lifecycle

    case Lifecycle.validate(lifecycle) do
      {:ok, _} -> do_init(config, lifecycle)
      {:error, reason} -> {:stop, Error.new(:config_error, "Invalid lifecycle: #{reason}")}
    end
  end

  defp do_init(config, lifecycle) do
    initial_state = lifecycle.initial_state
    state_config = Map.get(lifecycle.states, initial_state, %StateConfig{})
    resolved = resolve_config(config, state_config)

    case init_memory(config.memory) do
      {:ok, memory_state, persisted_messages} ->
        # StateMachine invariant: no :system messages in data.messages.
        # Instructions come from resolved_config.instructions via providers.
        data = %{
          base_config: config,
          config: resolved,
          lifecycle: lifecycle,
          messages: persisted_messages,
          status: :idle,
          iteration: 0,
          middleware_metadata: %{},
          memory_state: memory_state,
          stream_info: nil
        }

        actions = timeout_actions(initial_state, lifecycle)
        {:ok, initial_state, data, actions}

      {:error, error} ->
        {:stop, error}
    end
  end

  # --- State enter ---

  @impl true
  def handle_event(:enter, old_state, new_state, data) do
    # Run on_exit for old state (skip on initial enter where old == new)
    if old_state != new_state do
      safe_lifecycle_callback(data.lifecycle.on_exit, old_state, old_state, new_state)
    end

    # Resolve config for new state
    state_config = Map.get(data.lifecycle.states, new_state, %StateConfig{})
    resolved = resolve_config(data.base_config, state_config)
    data = %{data | config: resolved}

    # Run on_enter for new state
    from = if old_state == new_state, do: :__init__, else: old_state
    safe_lifecycle_callback(data.lifecycle.on_enter, new_state, from, new_state)

    actions = timeout_actions(new_state, data.lifecycle)
    {:keep_state, data, actions}
  end

  # --- Run (synchronous) ---

  def handle_event(
        {:call, from},
        {:run, %Message{} = message},
        state_name,
        %{status: :idle} = data
      ) do
    data = %{data | status: :running, iteration: 0, middleware_metadata: %{}}
    messages = data.messages ++ [message]
    telemetry_meta = telemetry_metadata(data.config)

    :telemetry.execute(
      [:agora, :agent, :run, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    start_time = System.monotonic_time()
    Process.put(@run_start_key, start_time)

    {result, run_result, final_data} = safe_reasoning_loop(messages, data)

    Process.delete(@run_start_key)

    # Memory save + reload
    {result, final_data} = memory_save_and_reload(result, final_data)

    duration = System.monotonic_time() - start_time
    final_data = %{final_data | status: :idle}

    run_stop_meta =
      case result do
        {:ok, _response} -> telemetry_meta
        {:error, error} -> Map.put(telemetry_meta, :error, error)
      end

    :telemetry.execute(
      [:agora, :agent, :run, :stop],
      %{duration: duration, iterations: final_data.iteration},
      run_stop_meta
    )

    # Evaluate transitions against RunResult facts
    case evaluate_transitions(run_result, state_name, final_data) do
      {:transition, target, trigger} ->
        emit_transition_telemetry(state_name, target, trigger, data.config)
        {:next_state, target, final_data, [{:reply, from, result}]}

      :no_transition ->
        {:keep_state, final_data, [{:reply, from, result}]}
    end
  end

  def handle_event({:call, from}, {:run, _}, _state_name, %{status: status} = _data) do
    {:keep_state_and_data,
     [{:reply, from, Error.wrap(:config_error, "Agent is busy (status: #{status})")}]}
  end

  # --- Stream run ---

  def handle_event(
        {:call, from},
        {:stream_run, %Message{} = message},
        state_name,
        %{status: :idle} = data
      ) do
    {caller_pid, _tag} = from
    data = %{data | status: :streaming, iteration: 0, middleware_metadata: %{}}
    messages = data.messages ++ [message]
    # Capture old_messages AFTER appending user input so derive_facts excludes it
    old_messages = messages
    agent_ref = make_ref()
    agent_pid = self()
    telemetry_meta = telemetry_metadata(data.config)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    start_time = System.monotonic_time()

    {:ok, task_pid} =
      Task.Supervisor.start_child(Agora.StreamSupervisor, fn ->
        result = safe_streaming_loop(messages, data, caller_pid, agent_ref)

        send(
          agent_pid,
          {:stream_complete, agent_ref, start_time, state_name, old_messages, result}
        )
      end)

    monitor_ref = Process.monitor(task_pid)

    stream_info = %{
      ref: agent_ref,
      task_pid: task_pid,
      monitor_ref: monitor_ref,
      start_time: start_time
    }

    stream = Agora.Stream.new(agent_ref, task_pid, caller_pid)

    {:keep_state, %{data | messages: messages, stream_info: stream_info},
     [{:reply, from, {:ok, stream}}]}
  end

  def handle_event({:call, from}, {:stream_run, _}, _state_name, %{status: status} = _data) do
    {:keep_state_and_data,
     [{:reply, from, Error.wrap(:config_error, "Agent is busy (status: #{status})")}]}
  end

  # --- Query calls ---

  def handle_event({:call, from}, :get_messages, _state_name, data) do
    {:keep_state_and_data, [{:reply, from, data.messages}]}
  end

  def handle_event({:call, from}, :get_status, _state_name, data) do
    {:keep_state_and_data, [{:reply, from, data.status}]}
  end

  def handle_event({:call, from}, :get_lifecycle_state, state_name, _data) do
    {:keep_state_and_data, [{:reply, from, {:ok, state_name}}]}
  end

  def handle_event({:call, from}, :clear_memory, _state_name, %{memory_state: nil} = _data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, Error.new(:memory_error, "No memory backend configured")}}]}
  end

  def handle_event({:call, from}, :clear_memory, _state_name, data) do
    case Memory.clear(data.memory_state) do
      {:ok, new_memory_state} ->
        # StateMachine: no system messages to preserve
        data = %{data | memory_state: new_memory_state, messages: []}
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  # --- State timeout ---

  def handle_event(:state_timeout, :timeout, state_name, %{status: :streaming} = _data) do
    # Suppress state timeouts while streaming to prevent stale-state transitions.
    # The stream completion handler will evaluate transitions against the current state.
    Logger.debug(
      "[Agora.Agent.StateMachine] Suppressed state_timeout in #{inspect(state_name)} during streaming"
    )

    :keep_state_and_data
  end

  def handle_event(:state_timeout, :timeout, state_name, data) do
    case find_timeout_transition(state_name, data.lifecycle) do
      {:ok, target, trigger} ->
        emit_transition_telemetry(state_name, target, trigger, data.config)
        {:next_state, target, data}

      :none ->
        :keep_state_and_data
    end
  end

  # --- Info: stream completion ---

  def handle_event(
        :info,
        {:stream_complete, ref, start_time, _run_state_name, old_messages,
         {:ok, final_messages, state_updates}},
        current_state,
        %{stream_info: %{ref: ref}} = data
      ) do
    Process.demonitor(data.stream_info.monitor_ref, [:flush])
    telemetry_meta = telemetry_metadata(data.config)

    data = %{
      data
      | messages: final_messages,
        status: :idle,
        iteration: state_updates.iteration,
        middleware_metadata: state_updates.middleware_metadata,
        stream_info: nil
    }

    # Memory save — failure logged, agent still transitions to :idle
    data = stream_memory_save(data)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :stop],
      %{duration: System.monotonic_time() - start_time, iterations: data.iteration},
      telemetry_meta
    )

    # Derive facts from message delta and evaluate transitions against current state
    facts = derive_facts(old_messages, final_messages)

    outcome =
      if facts.final_response, do: {:done, facts.final_response}, else: nil

    case maybe_evaluate_stream_transitions(facts, outcome, current_state, data) do
      {:transition, target, trigger} ->
        emit_transition_telemetry(current_state, target, trigger, data.config)
        {:next_state, target, data}

      :no_transition ->
        # Re-arm state_timeout if configured for current state, since
        # the one-shot timeout may have been suppressed during streaming.
        actions = timeout_actions(current_state, data.lifecycle)
        {:keep_state, data, actions}
    end
  end

  def handle_event(
        :info,
        {:stream_complete, ref, start_time, _state_name, _old_messages,
         {:error, error, final_messages}},
        _current_state,
        %{stream_info: %{ref: ref}} = data
      ) do
    Process.demonitor(data.stream_info.monitor_ref, [:flush])
    telemetry_meta = telemetry_metadata(data.config)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :stop],
      %{duration: System.monotonic_time() - start_time, iterations: data.iteration},
      Map.put(telemetry_meta, :error, error)
    )

    {:keep_state, %{data | status: :idle, messages: final_messages, stream_info: nil}}
  end

  def handle_event(
        :info,
        {:DOWN, mref, :process, pid, _reason},
        _state_name,
        %{stream_info: %{monitor_ref: mref, task_pid: pid}} = data
      ) do
    telemetry_meta = telemetry_metadata(data.config)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :stop],
      %{
        duration: System.monotonic_time() - data.stream_info.start_time,
        iterations: data.iteration
      },
      Map.put(telemetry_meta, :error, Error.new(:streaming_error, "Stream task crashed"))
    )

    {:keep_state, %{data | status: :idle, stream_info: nil}}
  end

  # Ignore stray messages
  def handle_event(:info, _msg, _state_name, _data) do
    :keep_state_and_data
  end

  # --- Private: Config resolution ---

  defp resolve_config(%AgentConfig{} = base, %StateConfig{} = overlay) do
    %{
      base
      | instructions: overlay.instructions || base.instructions,
        tools: overlay.tools || base.tools,
        middleware: overlay.middleware || base.middleware,
        max_iterations: overlay.max_iterations || base.max_iterations,
        provider_opts: overlay.provider_opts || base.provider_opts
    }
  end

  # --- Private: Memory ---

  defp init_memory(nil), do: {:ok, nil, []}

  defp init_memory({_module, _opts} = memory_config) do
    with {:ok, memory_state} <- Memory.init(memory_config),
         {:ok, persisted_messages} <- Memory.get(memory_state) do
      non_system = Enum.reject(persisted_messages, &(&1.role == :system))
      {:ok, memory_state, non_system}
    end
  end

  defp memory_save_and_reload(result, %{memory_state: nil} = data), do: {result, data}

  defp memory_save_and_reload(result, data) do
    # StateMachine: data.messages never contains :system messages (invariant)
    case Memory.save(data.memory_state, data.messages) do
      {:ok, new_memory_state} ->
        case Memory.get(new_memory_state) do
          {:ok, bounded_messages} ->
            non_system = Enum.reject(bounded_messages, &(&1.role == :system))
            data = %{data | memory_state: new_memory_state, messages: non_system}
            {result, data}

          {:error, get_error} ->
            {override_result(result, get_error), %{data | memory_state: new_memory_state}}
        end

      {:error, save_error} ->
        {override_result(result, save_error), data}
    end
  end

  defp stream_memory_save(%{memory_state: nil} = data), do: data

  defp stream_memory_save(data) do
    case Memory.save(data.memory_state, data.messages) do
      {:ok, new_memory_state} ->
        case Memory.get(new_memory_state) do
          {:ok, bounded_messages} ->
            non_system = Enum.reject(bounded_messages, &(&1.role == :system))
            %{data | memory_state: new_memory_state, messages: non_system}

          {:error, error} ->
            Logger.warning("[Agora.Agent.StateMachine] Stream memory reload failed: #{error}")

            Agora.Telemetry.emit(
              [:agora, :agent, :stream_run, :memory_error],
              %{system_time: System.system_time()},
              %{error: error}
            )

            %{data | memory_state: new_memory_state}
        end

      {:error, error} ->
        Logger.warning("[Agora.Agent.StateMachine] Stream memory save failed: #{error}")

        Agora.Telemetry.emit(
          [:agora, :agent, :stream_run, :memory_error],
          %{system_time: System.system_time()},
          %{error: error}
        )

        data
    end
  end

  defp override_result({:ok, _response}, memory_error), do: {:error, memory_error}

  defp override_result({:error, %Error{} = original}, %Error{} = memory_error) do
    {:error,
     %{original | metadata: Map.put(original.metadata, :memory_error, to_string(memory_error))}}
  end

  # --- Private: Transition evaluation ---

  defp evaluate_transitions(nil, _state_name, _data), do: :no_transition

  defp evaluate_transitions(%Loop.RunResult{} = run_result, state_name, data) do
    do_evaluate(run_result.facts, run_result.outcome, state_name, data)
  end

  defp maybe_evaluate_stream_transitions(_facts, nil, _state_name, _data), do: :no_transition

  defp maybe_evaluate_stream_transitions(facts, outcome, state_name, data) do
    do_evaluate(facts, outcome, state_name, data)
  end

  defp do_evaluate(facts, outcome, state_name, data) do
    Enum.find_value(data.lifecycle.transitions, :no_transition, fn transition ->
      if transition.from == state_name && trigger_matches?(transition.trigger, facts, outcome) do
        ctx = %{facts: facts, outcome: outcome, from: state_name, to: transition.to}

        if transition.guard == nil || safe_guard_call(transition.guard, ctx) do
          {:transition, transition.to, transition.trigger}
        end
      end
    end)
  end

  defp trigger_matches?({:tool_call, name}, facts, _outcome) do
    Enum.any?(facts.tool_calls_made, fn tc -> tc.name == name end)
  end

  defp trigger_matches?({:tool_result, name, pred}, facts, _outcome) do
    Enum.any?(facts.tool_results, fn tr ->
      tr.name == name && safe_predicate_call(pred, tr, "tool_result predicate")
    end)
  end

  defp trigger_matches?({:message_match, pred}, _facts, {:done, response}) do
    safe_predicate_call(pred, response, "message_match predicate")
  end

  defp trigger_matches?({:message_match, _pred}, _facts, {:error, _}) do
    false
  end

  defp trigger_matches?({:state_timeout, _}, _facts, _outcome) do
    # State timeouts are handled by :state_timeout events, not run evaluation
    false
  end

  # --- Private: Timeout helpers ---

  defp timeout_actions(state_name, lifecycle) do
    case find_timeout_transition(state_name, lifecycle) do
      {:ok, _target, {:state_timeout, ms}} -> [{:state_timeout, ms, :timeout}]
      :none -> []
    end
  end

  defp find_timeout_transition(state_name, lifecycle) do
    case Enum.find(lifecycle.transitions, fn t ->
           t.from == state_name && match?({:state_timeout, _}, t.trigger)
         end) do
      %{to: target, trigger: trigger} -> {:ok, target, trigger}
      nil -> :none
    end
  end

  # --- Private: Derive facts from message delta (for streaming) ---

  defp derive_facts(old_messages, new_messages) do
    delta = Enum.drop(new_messages, length(old_messages))

    tool_calls =
      delta
      |> Enum.flat_map(fn msg -> msg.tool_calls || [] end)

    tool_results =
      delta
      |> Enum.flat_map(fn msg -> msg.tool_results || [] end)

    final_response =
      delta
      |> Enum.filter(fn msg -> msg.role == :assistant end)
      |> List.last()

    %{
      appended_messages: delta,
      tool_calls_made: tool_calls,
      tool_results: tool_results,
      final_response: final_response
    }
  end

  # --- Private: Safe wrappers ---

  defp safe_reasoning_loop(messages, data) do
    Process.put(@messages_key, messages)

    loop_state = %Loop.State{
      config: data.config,
      messages: messages,
      middleware_metadata: data.middleware_metadata,
      iteration: data.iteration,
      on_messages_update: fn msgs -> Process.put(@messages_key, msgs) end
    }

    %Loop.RunResult{outcome: outcome, state: final_loop_state} = run_result = Loop.run(loop_state)

    Process.delete(@messages_key)

    result =
      case outcome do
        {:done, response} -> {:ok, response}
        {:error, _} = err -> err
      end

    final_data = %{
      data
      | messages: final_loop_state.messages,
        iteration: final_loop_state.iteration,
        middleware_metadata: final_loop_state.middleware_metadata
    }

    {result, run_result, final_data}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      recovered_messages = Process.delete(@messages_key) || messages
      run_start = Process.delete(@run_start_key) || System.monotonic_time()

      error =
        Error.new(
          :unknown,
          format_crash(kind, reason),
          %{kind: to_string(kind), reason: format_crash_reason(reason)}
        )

      Agora.Telemetry.emit(
        [:agora, :agent, :run, :exception],
        %{duration: System.monotonic_time() - run_start},
        telemetry_metadata(data.config)
        |> Map.merge(%{
          kind: kind,
          reason: format_crash_reason(reason),
          stacktrace: stacktrace |> Exception.format_stacktrace() |> String.slice(0, 1000)
        })
      )

      {{:error, error}, nil, %{data | messages: recovered_messages}}
  end

  defp safe_streaming_loop(messages, data, caller, agent_ref) do
    emit_fn = fn event -> send(caller, {Agora.Stream, agent_ref, event}) end

    loop_state = %Loop.State{
      config: data.config,
      messages: messages,
      middleware_metadata: data.middleware_metadata,
      iteration: data.iteration,
      on_messages_update: nil
    }

    StreamLoop.run(loop_state, emit_fn)
  catch
    kind, reason ->
      error =
        Error.new(
          :unknown,
          format_crash(kind, reason),
          %{kind: to_string(kind), reason: format_crash_reason(reason)}
        )

      send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
      send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
      {:error, error, messages}
  end

  # --- Private: Telemetry ---

  defp telemetry_metadata(%AgentConfig{} = config) do
    %{
      provider: config.provider,
      model: config.model,
      agent_name: config.name,
      max_iterations: config.max_iterations
    }
  end

  defp emit_transition_telemetry(from, to, trigger, config) do
    Agora.Telemetry.emit(
      [:agora, :agent, :state_transition],
      %{system_time: System.system_time()},
      %{
        from_state: from,
        to_state: to,
        trigger: inspect(trigger),
        provider: config.provider,
        model: config.model,
        agent_name: config.name
      }
    )
  end

  # --- Private: Safe callback/guard wrappers ---

  defp safe_lifecycle_callback(callbacks, state_key, from, to) do
    case Map.get(callbacks, state_key) do
      nil ->
        :ok

      callback ->
        try do
          callback.(from, to)
        catch
          kind, reason ->
            Logger.warning(
              "[Agora.Agent.StateMachine] Lifecycle callback for #{inspect(state_key)} crashed: " <>
                format_crash(kind, reason)
            )
        end
    end
  end

  defp safe_predicate_call(pred, arg, label) do
    try do
      pred.(arg)
    catch
      kind, reason ->
        Logger.warning(
          "[Agora.Agent.StateMachine] #{label} crashed: " <>
            format_crash(kind, reason)
        )

        false
    end
  end

  defp safe_guard_call(guard, ctx) do
    try do
      guard.(ctx)
    catch
      kind, reason ->
        Logger.warning(
          "[Agora.Agent.StateMachine] Transition guard crashed: " <>
            format_crash(kind, reason)
        )

        false
    end
  end

  # --- Private: Crash formatting ---

  defp format_crash(:error, %{__exception__: true} = exception) do
    "Agent loop crashed: " <> Exception.message(exception)
  end

  defp format_crash(:error, reason) do
    "Agent loop crashed: " <> inspect(reason)
  end

  defp format_crash(:exit, reason) do
    "Agent loop exited: " <> inspect(reason)
  end

  defp format_crash(:throw, value) do
    "Agent loop threw: " <> inspect(value)
  end

  defp format_crash_reason(%{__exception__: true} = exception) do
    Exception.message(exception)
  end

  defp format_crash_reason(reason) do
    inspect(reason)
  end
end
