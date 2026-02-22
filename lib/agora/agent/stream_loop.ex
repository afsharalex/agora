defmodule Agora.Agent.StreamLoop do
  @moduledoc false

  # Extracted streaming reasoning loop shared by Server and StateMachine backends.
  #
  # Uses an `emit_fn` callback for event delivery instead of direct `send/2`,
  # making the loop testable in isolation and backend-agnostic.

  alias Agora.Agent.Loop.State
  alias Agora.{Error, Message, Provider, StreamEvent, ToolBroker}
  alias Agora.Middleware.{Chain, Context}
  alias Agora.Provider.StreamAccumulator

  @type emit_fn :: (StreamEvent.t() -> :ok)

  @doc false
  @spec run(State.t(), emit_fn()) ::
          {:ok, [Message.t()], map()} | {:error, Error.t(), [Message.t()]}
  def run(%State{} = state, emit_fn) do
    streaming_loop(state.messages, state, emit_fn, 0, state.middleware_metadata)
  catch
    {:halt, error, msgs} -> {:error, error, msgs}
  end

  # --- Private: Main streaming recursion ---

  defp streaming_loop(messages, state, emit_fn, iteration, metadata) do
    config = state.config

    # Crash recovery hook: called at the start of each iteration
    if state.on_messages_update, do: state.on_messages_update.(messages)

    if iteration >= config.max_iterations do
      error =
        Error.new(:iteration_limit, "Reached maximum iterations (#{config.max_iterations})", %{
          max_iterations: config.max_iterations,
          iterations: iteration
        })

      emit_fn.(StreamEvent.error(error))
      emit_fn.(StreamEvent.done())
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
            emit_fn.(StreamEvent.error(error))
            emit_fn.(StreamEvent.done())
            throw({:halt, error, messages})
        end

      case Provider.stream_chat(config.provider, messages, config) do
        {:error, %Error{} = error} ->
          emit_fn.(StreamEvent.error(error))
          emit_fn.(StreamEvent.done())
          {:error, error, messages}

        {:ok, %{pid: provider_pid, ref: provider_ref}} ->
          relay_result =
            relay_events(
              provider_pid,
              provider_ref,
              emit_fn,
              StreamAccumulator.new(),
              middleware,
              metadata,
              messages,
              config
            )

          case relay_result do
            {:error, error, _acc, _metadata} ->
              emit_fn.(StreamEvent.done())
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
                    emit_fn.(StreamEvent.error(error))
                    emit_fn.(StreamEvent.done())
                    throw({:halt, error, messages ++ [message]})
                end

              if tool_calls != [] do
                assistant_msg = %{message | tool_calls: tool_calls}
                new_messages = messages ++ [assistant_msg]

                case execute_streaming_tools(
                       tool_calls,
                       config,
                       middleware,
                       metadata,
                       emit_fn
                     ) do
                  {:halt, error, _results, _metadata} ->
                    emit_fn.(StreamEvent.error(error))
                    emit_fn.(StreamEvent.done())
                    {:error, error, messages}

                  {:ok, tool_results, metadata} ->
                    tool_msg = Message.tool_results(tool_results)
                    new_messages = new_messages ++ [tool_msg]

                    streaming_loop(new_messages, state, emit_fn, iteration, metadata)
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

                emit_fn.(StreamEvent.message_complete(final_response))
                emit_fn.(StreamEvent.done())
                {:ok, new_messages, %{iteration: iteration, middleware_metadata: metadata}}
              end
          end
      end
    end
  catch
    {:halt, error, msgs} -> {:error, error, msgs}
  end

  # --- Private: Event relay ---

  defp relay_events(
         provider_pid,
         provider_ref,
         emit_fn,
         acc,
         middleware,
         metadata,
         messages,
         config
       ) do
    mref = Process.monitor(provider_pid)

    result =
      do_relay(mref, provider_ref, emit_fn, acc, middleware, metadata, messages, config)

    Process.demonitor(mref, [:flush])
    result
  end

  defp do_relay(mref, provider_ref, emit_fn, acc, middleware, metadata, messages, config) do
    receive do
      {Agora.Stream, ^provider_ref, %StreamEvent{type: :done}} ->
        {:ok, acc, metadata}

      {Agora.Stream, ^provider_ref, %StreamEvent{type: :error} = event} ->
        maybe_forward_event(event, emit_fn, middleware, metadata, messages, config)
        {:error, event.data, acc, metadata}

      {Agora.Stream, ^provider_ref, %StreamEvent{type: :message_complete}} ->
        # Provider sent message_complete — we'll send our own after middleware
        do_relay(mref, provider_ref, emit_fn, acc, middleware, metadata, messages, config)

      {Agora.Stream, ^provider_ref, %StreamEvent{} = event} ->
        acc = StreamAccumulator.apply(acc, event)

        {event, metadata} =
          maybe_run_stream_middleware(event, middleware, metadata, messages, config)

        if event, do: emit_fn.(event)

        do_relay(mref, provider_ref, emit_fn, acc, middleware, metadata, messages, config)

      {:DOWN, ^mref, :process, _, reason} ->
        error = Error.new(:streaming_error, "Provider stream crashed: #{inspect(reason)}")
        emit_fn.(StreamEvent.error(error))
        {:error, error, acc, metadata}
    after
      300_000 ->
        error = Error.new(:timeout, "Provider stream timed out after 300s")
        emit_fn.(StreamEvent.error(error))
        {:error, error, acc, metadata}
    end
  end

  # --- Private: Middleware helpers ---

  defp maybe_forward_event(event, emit_fn, middleware, metadata, messages, config) do
    {event, _metadata} =
      maybe_run_stream_middleware(event, middleware, metadata, messages, config)

    if event, do: emit_fn.(event)
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

  # --- Private: Tool execution ---

  defp execute_streaming_tools(tool_calls, config, middleware, metadata, emit_fn) do
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
        context = build_tool_context(config)
        {:ok, results} = ToolBroker.execute(tool_calls, config.tools, context)

        # Emit tool_result events via callback
        Enum.each(results, fn result ->
          emit_fn.(StreamEvent.tool_result(result))
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

  # --- Private: Tool context ---

  defp build_tool_context(config) do
    base = %{agent_name: config.name}

    case Keyword.get(config.provider_opts, :_agora_tool_depth) do
      nil -> base
      depth -> Map.put(base, :agora_tool_depth, depth)
    end
  end

  # --- Private: Halt reason normalization ---

  defp wrap_halt_reason(%Error{} = error), do: error

  defp wrap_halt_reason(reason) when is_binary(reason) do
    Error.new(:middleware_error, reason)
  end

  defp wrap_halt_reason(reason) do
    Error.new(:middleware_error, "Middleware halted: #{inspect(reason)}")
  end
end
