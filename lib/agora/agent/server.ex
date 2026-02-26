defmodule Agora.Agent.Server do
  @moduledoc false

  # GenServer backend for the agent. Delegates reasoning to Loop and StreamLoop.
  #
  # The reasoning loop is spawned as a supervised task under Agora.ToolSupervisor
  # so that hard-kill cancellation can terminate it. The GenServer blocks on
  # Task.yield(:infinity) to preserve mailbox-queuing semantics.

  use GenServer

  require Logger

  alias Agora.{AgentConfig, CancelToken, Error, Memory, Message, StreamEvent}
  alias Agora.Agent.{Loop, StreamLoop}

  @messages_key :agora_agent_loop_messages
  @run_start_key :agora_agent_run_start

  @spec start_link(AgentConfig.t(), keyword()) :: GenServer.on_start()
  def start_link(%AgentConfig{} = config, server_opts) do
    GenServer.start_link(__MODULE__, config, server_opts)
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

  # --- GenServer callbacks ---

  @impl true
  def init(%AgentConfig{} = config) do
    system_messages =
      if config.instructions != "" do
        [Message.system(config.instructions)]
      else
        []
      end

    case init_memory(config.memory) do
      {:ok, memory_state, persisted_messages} ->
        messages = system_messages ++ persisted_messages

        {:ok,
         %{
           config: config,
           messages: messages,
           status: :idle,
           iteration: 0,
           middleware_metadata: %{},
           memory_state: memory_state,
           stream_info: nil
         }}

      {:error, error} ->
        {:stop, error}
    end
  end

  defp init_memory(nil), do: {:ok, nil, []}

  defp init_memory({_module, _opts} = memory_config) do
    with {:ok, memory_state} <- Memory.init(memory_config),
         {:ok, persisted_messages} <- Memory.get(memory_state) do
      non_system = Enum.reject(persisted_messages, &(&1.role == :system))
      {:ok, memory_state, non_system}
    end
  end

  # New 3-tuple format with opts
  @impl true
  def handle_call({:run, %Message{} = message, opts}, _from, %{status: :idle} = state) do
    case validate_run_opts(opts) do
      {:error, _} = error ->
        {:reply, error, state}

      :ok ->
        do_handle_run(message, opts, state)
    end
  end

  # Backward compat: old 2-tuple format without opts
  def handle_call({:run, %Message{} = message}, from, state) do
    handle_call({:run, message, []}, from, state)
  end

  def handle_call({:run, _, _}, _from, %{status: status} = state) do
    {:reply, Error.wrap(:config_error, "Agent is busy (status: #{status})"), state}
  end

  def handle_call({:run, _}, _from, %{status: status} = state) do
    {:reply, Error.wrap(:config_error, "Agent is busy (status: #{status})"), state}
  end

  # New 3-tuple format with opts
  def handle_call(
        {:stream_run, %Message{} = message, opts},
        {caller_pid, _tag},
        %{status: :idle} = state
      ) do
    case validate_run_opts(opts) do
      {:error, _} = error ->
        {:reply, error, state}

      :ok ->
        do_handle_stream_run(message, opts, caller_pid, state)
    end
  end

  # Backward compat: old 2-tuple format without opts
  def handle_call({:stream_run, %Message{} = message}, from, state) do
    handle_call({:stream_run, message, []}, from, state)
  end

  def handle_call({:stream_run, _, _}, _from, %{status: status} = state) do
    {:reply, Error.wrap(:config_error, "Agent is busy (status: #{status})"), state}
  end

  def handle_call({:stream_run, _}, _from, %{status: status} = state) do
    {:reply, Error.wrap(:config_error, "Agent is busy (status: #{status})"), state}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:get_lifecycle_state, _from, state) do
    {:reply, {:error, Error.new(:config_error, "Not a state machine agent")}, state}
  end

  def handle_call(:clear_memory, _from, %{memory_state: nil} = state) do
    {:reply, {:error, Error.new(:memory_error, "No memory backend configured")}, state}
  end

  def handle_call(:clear_memory, _from, state) do
    case Memory.clear(state.memory_state) do
      {:ok, new_memory_state} ->
        system_msgs = Enum.filter(state.messages, &(&1.role == :system))
        state = %{state | memory_state: new_memory_state, messages: system_msgs}
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  # --- Private: Run helpers (extracted to keep handle_call clauses grouped) ---

  defp validate_run_opts(opts) when is_list(opts) do
    cancel_token = Keyword.get(opts, :cancel_token)

    if cancel_token != nil and not match?(%CancelToken{}, cancel_token) do
      {:error,
       Error.new(
         :config_error,
         ":cancel_token must be a %CancelToken{} struct, got: #{inspect(cancel_token)}"
       )}
    else
      :ok
    end
  end

  defp validate_run_opts(opts) do
    {:error,
     Error.new(
       :config_error,
       "opts must be a keyword list, got: #{inspect(opts)}"
     )}
  end

  defp do_handle_run(message, opts, state) do
    cancel_token = Keyword.get(opts, :cancel_token)
    state = %{state | status: :running, iteration: 0, middleware_metadata: %{}}
    messages = state.messages ++ [message]
    telemetry_meta = telemetry_metadata(state.config)

    :telemetry.execute(
      [:agora, :agent, :run, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    start_time = System.monotonic_time()
    Process.put(@run_start_key, start_time)

    # Spawn reasoning loop as killable task
    task =
      if cancel_token do
        t =
          Task.Supervisor.async_nolink(Agora.ToolSupervisor, fn ->
            receive do
              :registered -> safe_reasoning_loop(messages, state, cancel_token, start_time)
            end
          end)

        CancelToken.register(cancel_token, t.pid)
        send(t.pid, :registered)
        t
      else
        Task.Supervisor.async_nolink(Agora.ToolSupervisor, fn ->
          safe_reasoning_loop(messages, state, cancel_token, start_time)
        end)
      end

    {result, final_state} =
      case Task.yield(task, :infinity) do
        {:ok, {result, loop_state_updates}} ->
          {result, apply_loop_state(state, loop_state_updates)}

        {:exit, :killed} ->
          # Hard-killed: can't recover loop state from task
          {{:error, Error.new(:cancelled, "Agent execution killed")},
           %{state | messages: messages}}

        {:exit, reason} ->
          {{:error, Error.new(:unknown, "Reasoning loop crashed: #{inspect(reason)}")},
           %{state | messages: messages}}
      end

    if cancel_token, do: CancelToken.unregister(cancel_token, task.pid)

    Process.delete(@run_start_key)

    # Memory save + reload — after loop, before telemetry/reply
    {result, final_state} = memory_save_and_reload(result, final_state)

    duration = System.monotonic_time() - start_time
    final_state = %{final_state | status: :idle}

    run_stop_meta =
      case result do
        {:ok, _response} -> telemetry_meta
        {:error, error} -> Map.put(telemetry_meta, :error, error)
      end

    :telemetry.execute(
      [:agora, :agent, :run, :stop],
      %{duration: duration, iterations: final_state.iteration},
      run_stop_meta
    )

    {:reply, result, final_state}
  end

  defp do_handle_stream_run(message, opts, caller_pid, state) do
    cancel_token = Keyword.get(opts, :cancel_token)
    state = %{state | status: :streaming, iteration: 0, middleware_metadata: %{}}
    messages = state.messages ++ [message]
    agent_ref = make_ref()
    agent_pid = self()
    telemetry_meta = telemetry_metadata(state.config)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    start_time = System.monotonic_time()

    {:ok, task_pid} =
      if cancel_token do
        {:ok, pid} =
          Task.Supervisor.start_child(Agora.StreamSupervisor, fn ->
            receive do
              :registered ->
                result =
                  safe_streaming_loop(messages, state, caller_pid, agent_ref, cancel_token)

                send(agent_pid, {:stream_complete, agent_ref, start_time, result})
            end
          end)

        CancelToken.register(cancel_token, pid)
        send(pid, :registered)
        {:ok, pid}
      else
        Task.Supervisor.start_child(Agora.StreamSupervisor, fn ->
          result = safe_streaming_loop(messages, state, caller_pid, agent_ref, cancel_token)
          send(agent_pid, {:stream_complete, agent_ref, start_time, result})
        end)
      end

    monitor_ref = Process.monitor(task_pid)

    stream_info = %{
      ref: agent_ref,
      task_pid: task_pid,
      monitor_ref: monitor_ref,
      start_time: start_time
    }

    stream = Agora.Stream.new(agent_ref, task_pid, caller_pid)

    {:reply, {:ok, stream}, %{state | messages: messages, stream_info: stream_info}}
  end

  @impl true
  def handle_info(
        {:stream_complete, ref, start_time, {:ok, final_messages, state_updates}},
        %{stream_info: %{ref: ref}} = state
      ) do
    Process.demonitor(state.stream_info.monitor_ref, [:flush])
    telemetry_meta = telemetry_metadata(state.config)

    state = %{
      state
      | messages: final_messages,
        status: :idle,
        iteration: state_updates.iteration,
        middleware_metadata: state_updates.middleware_metadata,
        stream_info: nil
    }

    # Memory save — failure logged, agent still transitions to :idle
    state = stream_memory_save(state)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :stop],
      %{duration: System.monotonic_time() - start_time, iterations: state.iteration},
      telemetry_meta
    )

    {:noreply, state}
  end

  def handle_info(
        {:stream_complete, ref, start_time, {:error, error, final_messages}},
        %{stream_info: %{ref: ref}} = state
      ) do
    Process.demonitor(state.stream_info.monitor_ref, [:flush])
    telemetry_meta = telemetry_metadata(state.config)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :stop],
      %{duration: System.monotonic_time() - start_time, iterations: state.iteration},
      Map.put(telemetry_meta, :error, error)
    )

    {:noreply, %{state | status: :idle, messages: final_messages, stream_info: nil}}
  end

  def handle_info(
        {:DOWN, mref, :process, pid, reason},
        %{stream_info: %{monitor_ref: mref, task_pid: pid}} = state
      ) do
    telemetry_meta = telemetry_metadata(state.config)

    error =
      if reason == :killed do
        Error.new(:cancelled, "Stream task killed")
      else
        Error.new(:streaming_error, "Stream task crashed: #{inspect(reason)}")
      end

    :telemetry.execute(
      [:agora, :agent, :stream_run, :stop],
      %{
        duration: System.monotonic_time() - state.stream_info.start_time,
        iterations: state.iteration
      },
      Map.put(telemetry_meta, :error, error)
    )

    {:noreply, %{state | status: :idle, stream_info: nil}}
  end

  # Ignore stray messages (other refs, other :DOWN, other :stream_complete)
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private: Apply loop state updates ---

  defp apply_loop_state(state, %{
         messages: messages,
         iteration: iteration,
         middleware_metadata: mm
       }) do
    %{state | messages: messages, iteration: iteration, middleware_metadata: mm}
  end

  # --- Private: Memory save + reload ---

  defp memory_save_and_reload(result, %{memory_state: nil} = state), do: {result, state}

  defp memory_save_and_reload(result, state) do
    non_system = Enum.reject(state.messages, &(&1.role == :system))

    case Memory.save(state.memory_state, non_system) do
      {:ok, new_memory_state} ->
        case Memory.get(new_memory_state) do
          {:ok, bounded_messages} ->
            system_msgs = Enum.filter(state.messages, &(&1.role == :system))

            state = %{
              state
              | memory_state: new_memory_state,
                messages: system_msgs ++ bounded_messages
            }

            {result, state}

          {:error, get_error} ->
            {override_result(result, get_error), %{state | memory_state: new_memory_state}}
        end

      {:error, save_error} ->
        {override_result(result, save_error), state}
    end
  end

  defp override_result({:ok, _response}, memory_error), do: {:error, memory_error}

  defp override_result({:error, %Error{} = original}, %Error{} = memory_error) do
    {:error,
     %{original | metadata: Map.put(original.metadata, :memory_error, to_string(memory_error))}}
  end

  # --- Private: Safe wrappers (run inside spawned task) ---

  defp safe_reasoning_loop(messages, state, cancel_token, run_start_time) do
    Process.put(@messages_key, messages)

    loop_state = %Loop.State{
      config: state.config,
      messages: messages,
      middleware_metadata: state.middleware_metadata,
      iteration: state.iteration,
      on_messages_update: fn msgs -> Process.put(@messages_key, msgs) end,
      cancel_token: cancel_token
    }

    %Loop.RunResult{outcome: outcome, state: final_loop_state} = Loop.run(loop_state)

    Process.delete(@messages_key)

    result =
      case outcome do
        {:done, response} -> {:ok, response}
        {:error, _} = err -> err
      end

    loop_state_updates = %{
      messages: final_loop_state.messages,
      iteration: final_loop_state.iteration,
      middleware_metadata: final_loop_state.middleware_metadata
    }

    {result, loop_state_updates}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      recovered_messages = Process.delete(@messages_key) || messages
      run_start = run_start_time

      error =
        Error.new(
          :unknown,
          format_crash(kind, reason),
          %{kind: to_string(kind), reason: format_crash_reason(reason)}
        )

      Agora.Telemetry.emit(
        [:agora, :agent, :run, :exception],
        %{duration: System.monotonic_time() - run_start},
        telemetry_metadata(state.config)
        |> Map.merge(%{
          kind: kind,
          reason: format_crash_reason(reason),
          stacktrace: stacktrace |> Exception.format_stacktrace() |> String.slice(0, 1000)
        })
      )

      {{:error, error},
       %{
         messages: recovered_messages,
         iteration: state.iteration,
         middleware_metadata: state.middleware_metadata
       }}
  end

  defp safe_streaming_loop(messages, state, caller, agent_ref, cancel_token) do
    emit_fn = fn event -> send(caller, {Agora.Stream, agent_ref, event}) end

    loop_state = %Loop.State{
      config: state.config,
      messages: messages,
      middleware_metadata: state.middleware_metadata,
      iteration: state.iteration,
      on_messages_update: nil,
      cancel_token: cancel_token
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

  # --- Private: Stream memory save ---

  defp stream_memory_save(%{memory_state: nil} = state), do: state

  defp stream_memory_save(state) do
    non_system = Enum.reject(state.messages, &(&1.role == :system))

    case Memory.save(state.memory_state, non_system) do
      {:ok, new_memory_state} ->
        case Memory.get(new_memory_state) do
          {:ok, bounded_messages} ->
            system_msgs = Enum.filter(state.messages, &(&1.role == :system))

            %{
              state
              | memory_state: new_memory_state,
                messages: system_msgs ++ bounded_messages
            }

          {:error, error} ->
            Logger.warning("[Agora.Agent] Stream memory reload failed: #{error}")

            Agora.Telemetry.emit(
              [:agora, :agent, :stream_run, :memory_error],
              %{system_time: System.system_time()},
              %{error: error}
            )

            %{state | memory_state: new_memory_state}
        end

      {:error, error} ->
        Logger.warning("[Agora.Agent] Stream memory save failed: #{error}")

        Agora.Telemetry.emit(
          [:agora, :agent, :stream_run, :memory_error],
          %{system_time: System.system_time()},
          %{error: error}
        )

        state
    end
  end

  # --- Private: Telemetry helpers ---

  defp telemetry_metadata(%AgentConfig{} = config) do
    %{
      provider: config.provider,
      model: config.model,
      agent_name: config.name,
      max_iterations: config.max_iterations
    }
  end

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
