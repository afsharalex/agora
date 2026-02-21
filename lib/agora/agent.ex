defmodule Agora.Agent do
  @moduledoc """
  GenServer implementing the core agent reasoning loop.

  An agent receives user input, calls the LLM provider, detects tool calls,
  executes them via `ToolBroker`, feeds results back, and repeats until a final
  text response or iteration limit is reached.

  ## Middleware

  The reasoning loop supports middleware — composable interceptors at four
  hook points: `:before_provider_call`, `:after_provider_call`,
  `:before_tool_call`, and `:after_tool_call`. When `config.middleware` is
  empty, the loop runs with zero middleware overhead (no context construction).

  ## Concurrency

  `run/2` uses `GenServer.call` with `:infinity` timeout. Because the reasoning
  loop executes inside `handle_call`, concurrent `run/2` calls queue behind each
  other (standard GenServer mailbox serialization). The iteration limit on the
  agent config bounds each individual run. `get_messages/1` and `get_status/1`
  also queue — they return accurate state between runs but are not observable
  during a run.

  ## Example

      config = AgentConfig.new!(
        provider: :echo,
        model: "echo",
        instructions: "You are a helpful assistant."
      )

      {:ok, pid} = Agora.Agent.start_link(config: config)
      {:ok, response} = Agora.Agent.run(pid, "Hello!")
      response.content
      #=> "Echo: Hello!"

  ## State

  The agent maintains conversation history across `run/2` calls. Each call
  appends the user message, then enters the reasoning loop until the provider
  returns a text response (no tool calls) or the iteration limit is hit.
  """

  use GenServer

  require Logger

  alias Agora.{AgentConfig, Error, Memory, Message, Provider, StreamEvent, ToolBroker}
  alias Agora.Agent.Loop
  alias Agora.Middleware.{Chain, Context}
  alias Agora.Provider.StreamAccumulator

  @type status :: :idle | :running | :streaming

  @messages_key :agora_agent_loop_messages
  @run_start_key :agora_agent_run_start

  @doc """
  Starts an agent process.

  ## Options

    * `:config` (required) — an `%AgentConfig{}` struct
    * `:name` — optional GenServer name registration

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {config, server_opts} = Keyword.pop!(opts, :config)
    GenServer.start_link(__MODULE__, config, server_opts)
  end

  @doc """
  Sends a message to the agent and returns the final assistant response.

  Accepts a string (converted to a user message) or a `%Message{}` struct.
  Blocks until the reasoning loop completes. Concurrent calls queue behind
  each other due to GenServer serialization.

  Returns `{:ok, %Message{}}` on success or `{:error, %Error{}}` on failure.
  """
  @spec run(GenServer.server(), String.t() | Message.t()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def run(agent, input) when is_binary(input) do
    run(agent, Message.user(input))
  end

  def run(agent, %Message{} = message) do
    GenServer.call(agent, {:run, message}, :infinity)
  end

  @doc """
  Sends a message and returns a stream of incremental events.

  Unlike `run/2`, this returns immediately with an `Agora.Stream` that the
  caller can enumerate to receive `StreamEvent` structs as the provider
  generates tokens. The GenServer remains responsive during streaming.

  Returns `{:error, %Error{}}` if the agent is busy or the provider does
  not support streaming.
  """
  @spec stream_run(GenServer.server(), String.t() | Message.t()) ::
          {:ok, Agora.Stream.t()} | {:error, Error.t()}
  def stream_run(agent, input) when is_binary(input) do
    stream_run(agent, Message.user(input))
  end

  def stream_run(agent, %Message{} = message) do
    GenServer.call(agent, {:stream_run, message}, :infinity)
  end

  @doc """
  Returns the current conversation history.
  """
  @spec get_messages(GenServer.server()) :: [Message.t()]
  def get_messages(agent) do
    GenServer.call(agent, :get_messages)
  end

  @doc """
  Returns the current agent status.

  Note: because `run/2` executes synchronously inside `handle_call`, this
  will always return `:idle` (calls queue behind any active run).
  """
  @spec get_status(GenServer.server()) :: status()
  def get_status(agent) do
    GenServer.call(agent, :get_status)
  end

  @doc """
  Clears the agent's memory backend, removing all persisted messages.

  Returns `:ok` on success. Returns `{:error, %Error{}}` if no memory
  backend is configured or if the clear operation fails.
  """
  @spec clear_memory(GenServer.server()) :: :ok | {:error, Error.t()}
  def clear_memory(agent) do
    GenServer.call(agent, :clear_memory)
  end

  @doc false
  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)
    restart = if config.memory, do: :transient, else: :temporary

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
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
      # Filter out any persisted system messages — system prompt is reconstructed
      # from config.instructions and should never come from storage.
      non_system = Enum.reject(persisted_messages, &(&1.role == :system))
      {:ok, memory_state, non_system}
    end
  end

  @impl true
  def handle_call({:run, %Message{} = message}, _from, %{status: :idle} = state) do
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

    {result, final_state} = safe_reasoning_loop(messages, state)

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

  def handle_call({:run, _}, _from, %{status: status} = state) do
    {:reply, Error.wrap(:config_error, "Agent is busy (status: #{status})"), state}
  end

  def handle_call(
        {:stream_run, %Message{} = message},
        {caller_pid, _tag},
        %{status: :idle} = state
      ) do
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
      Task.Supervisor.start_child(Agora.StreamSupervisor, fn ->
        result = safe_streaming_loop(messages, state, caller_pid, agent_ref)
        send(agent_pid, {:stream_complete, agent_ref, start_time, result})
      end)

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

  def handle_call({:stream_run, _}, _from, %{status: status} = state) do
    {:reply, Error.wrap(:config_error, "Agent is busy (status: #{status})"), state}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
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
        {:DOWN, mref, :process, pid, _reason},
        %{stream_info: %{monitor_ref: mref, task_pid: pid}} = state
      ) do
    telemetry_meta = telemetry_metadata(state.config)

    :telemetry.execute(
      [:agora, :agent, :stream_run, :stop],
      %{
        duration: System.monotonic_time() - state.stream_info.start_time,
        iterations: state.iteration
      },
      Map.put(telemetry_meta, :error, Error.new(:streaming_error, "Stream task crashed"))
    )

    {:noreply, %{state | status: :idle, stream_info: nil}}
  end

  # Ignore stray messages (other refs, other :DOWN, other :stream_complete)
  def handle_info(_msg, state) do
    {:noreply, state}
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

  # --- Private: Safe wrapper ---

  defp safe_reasoning_loop(messages, state) do
    Process.put(@messages_key, messages)

    loop_state = %Loop.State{
      config: state.config,
      messages: messages,
      middleware_metadata: state.middleware_metadata,
      iteration: state.iteration,
      on_messages_update: fn msgs -> Process.put(@messages_key, msgs) end
    }

    %Loop.RunResult{outcome: outcome, state: final_loop_state} = Loop.run(loop_state)

    Process.delete(@messages_key)

    result =
      case outcome do
        {:done, response} -> {:ok, response}
        {:error, _} = err -> err
      end

    final_state = %{
      state
      | messages: final_loop_state.messages,
        iteration: final_loop_state.iteration,
        middleware_metadata: final_loop_state.middleware_metadata
    }

    {result, final_state}
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
        telemetry_metadata(state.config)
        |> Map.merge(%{
          kind: kind,
          reason: format_crash_reason(reason),
          stacktrace: stacktrace |> Exception.format_stacktrace() |> String.slice(0, 1000)
        })
      )

      {{:error, error}, %{state | messages: recovered_messages}}
  end

  # --- Private: Halt reason normalization (used by streaming path) ---

  defp wrap_halt_reason(%Error{} = error), do: error

  defp wrap_halt_reason(reason) when is_binary(reason) do
    Error.new(:middleware_error, reason)
  end

  defp wrap_halt_reason(reason) do
    Error.new(:middleware_error, "Middleware halted: #{inspect(reason)}")
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

  # --- Private: Streaming loop ---

  defp safe_streaming_loop(messages, state, caller, agent_ref) do
    streaming_loop(messages, state, caller, agent_ref, 0, state.middleware_metadata)
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

  defp streaming_loop(messages, state, caller, agent_ref, iteration, metadata) do
    config = state.config

    if iteration >= config.max_iterations do
      error =
        Error.new(:iteration_limit, "Reached maximum iterations (#{config.max_iterations})", %{
          max_iterations: config.max_iterations,
          iterations: iteration
        })

      send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
      send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
      {:error, error, messages}
    else
      iteration = iteration + 1
      middleware = config.middleware

      # Run :before_provider_call middleware
      {messages, config, metadata} =
        case run_streaming_hook(:before_provider_call, messages, config, middleware, metadata) do
          {:ok, ctx} ->
            {ctx.messages, ctx.config, ctx.metadata}

          {:halt, reason} ->
            error = wrap_halt_reason(reason)
            send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
            send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
            throw({:halt, error, messages})
        end

      case Provider.stream_chat(config.provider, messages, config) do
        {:error, %Error{} = error} ->
          send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
          send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
          {:error, error, messages}

        {:ok, %{pid: provider_pid, ref: provider_ref}} ->
          # Relay events from provider to caller, accumulating the message
          relay_result =
            relay_events(
              provider_pid,
              provider_ref,
              caller,
              agent_ref,
              StreamAccumulator.new(),
              middleware,
              metadata,
              messages,
              config
            )

          case relay_result do
            {:error, error, _acc, _metadata} ->
              # Provider crashed/timed out/errored — do NOT persist partial content
              send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
              {:error, error, messages}

            {:ok, acc, metadata} ->
              message = StreamAccumulator.to_message(acc)

              # Run :after_provider_call middleware
              {message, tool_calls, metadata} =
                case run_after_provider_call(message, messages, config, middleware, metadata) do
                  {:ok, ctx} ->
                    {ctx.response, ctx.tool_calls, ctx.metadata}

                  {:halt, reason} ->
                    error = wrap_halt_reason(reason)
                    send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
                    send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
                    throw({:halt, error, messages ++ [message]})
                end

              if tool_calls != [] do
                # Execute tools and emit tool_result events
                assistant_msg = %{message | tool_calls: tool_calls}
                new_messages = messages ++ [assistant_msg]

                case execute_streaming_tools(
                       tool_calls,
                       config,
                       middleware,
                       metadata,
                       caller,
                       agent_ref
                     ) do
                  {:halt, error, _results, _metadata} ->
                    # Middleware halted tool execution — don't persist the partial turn
                    # (assistant + tool results). Roll back to pre-tool-turn state.
                    send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
                    send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
                    {:error, error, messages}

                  {:ok, tool_results, metadata} ->
                    tool_msg = Message.tool_results(tool_results)
                    new_messages = new_messages ++ [tool_msg]

                    # Continue the loop for next provider call
                    streaming_loop(new_messages, state, caller, agent_ref, iteration, metadata)
                end
              else
                # Final text response — done
                final_response =
                  if message.tool_calls != [] do
                    %{message | tool_calls: []}
                  else
                    message
                  end

                new_messages = messages ++ [final_response]

                send(
                  caller,
                  {Agora.Stream, agent_ref, StreamEvent.message_complete(final_response)}
                )

                send(caller, {Agora.Stream, agent_ref, StreamEvent.done()})
                {:ok, new_messages, %{iteration: iteration, middleware_metadata: metadata}}
              end
          end
      end
    end
  catch
    {:halt, error, msgs} -> {:error, error, msgs}
  end

  defp relay_events(
         provider_pid,
         provider_ref,
         caller,
         agent_ref,
         acc,
         middleware,
         metadata,
         messages,
         config
       ) do
    mref = Process.monitor(provider_pid)

    result =
      do_relay(mref, provider_ref, caller, agent_ref, acc, middleware, metadata, messages, config)

    Process.demonitor(mref, [:flush])
    result
  end

  defp do_relay(
         mref,
         provider_ref,
         caller,
         agent_ref,
         acc,
         middleware,
         metadata,
         messages,
         config
       ) do
    receive do
      {Agora.Stream, ^provider_ref, %StreamEvent{type: :done}} ->
        {:ok, acc, metadata}

      {Agora.Stream, ^provider_ref, %StreamEvent{type: :error} = event} ->
        maybe_forward_event(event, caller, agent_ref, middleware, metadata, messages, config)
        {:error, event.data, acc, metadata}

      {Agora.Stream, ^provider_ref, %StreamEvent{type: :message_complete}} ->
        # Provider sent message_complete — we'll send our own after middleware
        do_relay(
          mref,
          provider_ref,
          caller,
          agent_ref,
          acc,
          middleware,
          metadata,
          messages,
          config
        )

      {Agora.Stream, ^provider_ref, %StreamEvent{} = event} ->
        acc = StreamAccumulator.apply(acc, event)

        {event, metadata} =
          maybe_run_stream_middleware(event, middleware, metadata, messages, config)

        if event, do: send(caller, {Agora.Stream, agent_ref, event})

        do_relay(
          mref,
          provider_ref,
          caller,
          agent_ref,
          acc,
          middleware,
          metadata,
          messages,
          config
        )

      {:DOWN, ^mref, :process, _, reason} ->
        error = Error.new(:streaming_error, "Provider stream crashed: #{inspect(reason)}")
        send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
        {:error, error, acc, metadata}
    after
      300_000 ->
        error = Error.new(:timeout, "Provider stream timed out after 300s")
        send(caller, {Agora.Stream, agent_ref, StreamEvent.error(error)})
        {:error, error, acc, metadata}
    end
  end

  defp maybe_forward_event(event, caller, agent_ref, middleware, metadata, messages, config) do
    {event, _metadata} =
      maybe_run_stream_middleware(event, middleware, metadata, messages, config)

    if event, do: send(caller, {Agora.Stream, agent_ref, event})
  end

  defp maybe_run_stream_middleware(event, [], _metadata, _messages, _config) do
    {event, %{}}
  end

  defp maybe_run_stream_middleware(event, middleware, metadata, messages, config) do
    ctx =
      Context.new(
        hook: :on_stream_event,
        stream_event: event,
        messages: messages,
        config: config,
        metadata: metadata
      )

    case Chain.run(middleware, ctx) do
      {:ok, ctx} -> {ctx.stream_event, ctx.metadata}
      {:halt, _reason} -> {nil, metadata}
    end
  end

  defp run_streaming_hook(_hook, messages, config, [], metadata) do
    {:ok,
     Context.new(
       hook: :before_provider_call,
       messages: messages,
       config: config,
       metadata: metadata
     )}
  end

  defp run_streaming_hook(hook, messages, config, middleware, metadata) do
    ctx =
      Context.new(
        hook: hook,
        messages: messages,
        config: config,
        metadata: metadata
      )

    Chain.run(middleware, ctx)
  end

  defp run_after_provider_call(response, messages, config, [], metadata) do
    {:ok,
     Context.new(
       hook: :after_provider_call,
       response: response,
       tool_calls: response.tool_calls,
       messages: messages,
       config: config,
       metadata: metadata
     )}
  end

  defp run_after_provider_call(response, messages, config, middleware, metadata) do
    ctx =
      Context.new(
        hook: :after_provider_call,
        messages: messages,
        response: response,
        tool_calls: response.tool_calls,
        config: config,
        metadata: metadata
      )

    Chain.run(middleware, ctx)
  end

  defp execute_streaming_tools(tool_calls, config, middleware, metadata, caller, agent_ref) do
    # Run :before_tool_call middleware if present
    {tool_calls, metadata, halted?} =
      if middleware != [] do
        ctx =
          Context.new(
            hook: :before_tool_call,
            tool_calls: tool_calls,
            config: config,
            metadata: metadata
          )

        case Chain.run(middleware, ctx) do
          {:ok, ctx} -> {ctx.tool_calls, ctx.metadata, false}
          {:halt, reason} -> {[], metadata, {:halt, reason}}
        end
      else
        {tool_calls, metadata, false}
      end

    case halted? do
      {:halt, reason} ->
        error = wrap_halt_reason(reason)
        {:halt, error, [], metadata}

      false ->
        {:ok, results} = ToolBroker.execute(tool_calls, config.tools)

        # Emit tool_result events to caller
        Enum.each(results, fn result ->
          send(caller, {Agora.Stream, agent_ref, StreamEvent.tool_result(result)})
        end)

        # Run :after_tool_call middleware if present
        if middleware != [] do
          ctx =
            Context.new(
              hook: :after_tool_call,
              tool_calls: tool_calls,
              tool_results: results,
              config: config,
              metadata: metadata
            )

          case Chain.run(middleware, ctx) do
            {:ok, ctx} -> {:ok, results, ctx.metadata}
            {:halt, reason} -> {:halt, wrap_halt_reason(reason), results, metadata}
          end
        else
          {:ok, results, metadata}
        end
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
