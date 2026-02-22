defmodule Agora.Agent.Loop do
  @moduledoc false

  # Extracted sync reasoning loop shared by Server and StateMachine backends.
  #
  # The loop takes a State struct (with callback hooks for process-specific concerns)
  # and returns a RunResult with the outcome, updated state, and accumulated facts
  # about what happened during execution.

  alias Agora.{AgentConfig, Error, Message, Provider, ToolBroker}
  alias Agora.Middleware.{Chain, Context}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            config: Agora.AgentConfig.t(),
            messages: [Agora.Message.t()],
            middleware_metadata: map(),
            iteration: non_neg_integer(),
            on_messages_update: (list() -> :ok) | nil
          }

    defstruct [:config, :messages, :on_messages_update, middleware_metadata: %{}, iteration: 0]
  end

  defmodule RunResult do
    @moduledoc false

    @type facts :: %{
            appended_messages: [Agora.Message.t()],
            tool_calls_made: [Agora.ToolCall.t()],
            tool_results: [Agora.ToolResult.t()],
            final_response: Agora.Message.t() | nil
          }

    @type t :: %__MODULE__{
            outcome: {:done, Agora.Message.t()} | {:error, Agora.Error.t()},
            state: State.t(),
            facts: facts()
          }

    defstruct [:outcome, :state, :facts]
  end

  @spec run(State.t()) :: RunResult.t()
  def run(%State{} = state) do
    facts = %{
      appended_messages: [],
      tool_calls_made: [],
      tool_results: [],
      final_response: nil
    }

    do_run(state, facts)
  end

  # --- Private: Main recursion ---

  defp do_run(%State{iteration: iteration, config: config} = state, facts) do
    # Crash recovery hook: called at the start of each iteration
    if state.on_messages_update, do: state.on_messages_update.(state.messages)

    if iteration >= config.max_iterations do
      error =
        Error.new(:iteration_limit, "Reached maximum iterations (#{config.max_iterations})", %{
          max_iterations: config.max_iterations,
          iterations: iteration
        })

      %RunResult{
        outcome: {:error, error},
        state: %{state | messages: state.messages},
        facts: facts
      }
    else
      iteration = iteration + 1
      state = %{state | iteration: iteration}
      telemetry_meta = telemetry_metadata(config)

      :telemetry.execute(
        [:agora, :agent, :loop_iteration, :start],
        %{system_time: System.system_time()},
        Map.put(telemetry_meta, :iteration, iteration)
      )

      iter_start = System.monotonic_time()
      middleware = config.middleware

      case do_iteration(state.messages, config, middleware, state.middleware_metadata) do
        {:continue, new_messages, new_metadata, iter_facts} ->
          :telemetry.execute(
            [:agora, :agent, :loop_iteration, :stop],
            %{duration: System.monotonic_time() - iter_start},
            telemetry_meta |> Map.put(:iteration, iteration) |> Map.put(:has_tool_calls, true)
          )

          # Accumulate facts from this iteration
          facts = merge_facts(facts, iter_facts)

          do_run(
            %{state | messages: new_messages, middleware_metadata: new_metadata},
            facts
          )

        {:done, response, new_messages, iter_facts} ->
          :telemetry.execute(
            [:agora, :agent, :loop_iteration, :stop],
            %{duration: System.monotonic_time() - iter_start},
            telemetry_meta |> Map.put(:iteration, iteration) |> Map.put(:has_tool_calls, false)
          )

          facts =
            merge_facts(facts, iter_facts)
            |> Map.put(:final_response, response)

          %RunResult{
            outcome: {:done, response},
            state: %{state | messages: new_messages},
            facts: facts
          }

        {:error, %Error{} = error} ->
          :telemetry.execute(
            [:agora, :agent, :loop_iteration, :stop],
            %{duration: System.monotonic_time() - iter_start},
            telemetry_meta |> Map.put(:iteration, iteration) |> Map.put(:error, error)
          )

          %RunResult{
            outcome: {:error, error},
            state: %{state | messages: state.messages},
            facts: facts
          }
      end
    end
  end

  # --- Private: Iteration (fast path — no middleware) ---

  defp do_iteration(messages, config, [], _metadata) do
    case Provider.chat(config.provider, messages, config) do
      {:ok, %Message{tool_calls: tool_calls} = response} when tool_calls != [] ->
        messages = messages ++ [response]
        context = build_tool_context(config)
        {:ok, results} = ToolBroker.execute(tool_calls, config.tools, context)
        tool_msg = Message.tool_results(results)
        messages = messages ++ [tool_msg]

        iter_facts = %{
          appended_messages: [response, tool_msg],
          tool_calls_made: tool_calls,
          tool_results: results
        }

        {:continue, messages, %{}, iter_facts}

      {:ok, %Message{} = response} ->
        messages = messages ++ [response]
        {:done, response, messages, %{appended_messages: [response]}}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # --- Private: Iteration (middleware path) ---

  defp do_iteration(messages, config, middleware, metadata) do
    # Hook 1: before_provider_call
    ctx =
      Context.new(
        hook: :before_provider_call,
        messages: messages,
        config: config,
        metadata: metadata
      )

    case Chain.run(middleware, ctx) do
      {:halt, reason} ->
        {:error, wrap_halt_reason(reason)}

      {:ok, ctx} ->
        iter_messages = ctx.messages
        iter_config = ctx.config
        metadata = ctx.metadata

        case Provider.chat(iter_config.provider, iter_messages, iter_config) do
          {:error, %Error{} = error} ->
            {:error, error}

          {:ok, %Message{} = response} ->
            # Hook 2: after_provider_call
            raw_tool_calls = response.tool_calls

            ctx =
              Context.new(
                hook: :after_provider_call,
                messages: iter_messages,
                response: response,
                tool_calls: raw_tool_calls,
                config: iter_config,
                metadata: metadata
              )

            case Chain.run(middleware, ctx) do
              {:halt, reason} ->
                {:error, wrap_halt_reason(reason)}

              {:ok, ctx} ->
                if ctx.tool_calls != [] do
                  handle_tool_calls(
                    iter_messages,
                    ctx.response,
                    ctx.tool_calls,
                    iter_config,
                    middleware,
                    ctx.metadata
                  )
                else
                  # Scrub stale tool_calls from response before persisting
                  final_response =
                    if ctx.response.tool_calls != [] do
                      %{ctx.response | tool_calls: []}
                    else
                      ctx.response
                    end

                  new_messages = iter_messages ++ [final_response]
                  {:done, final_response, new_messages, %{appended_messages: [final_response]}}
                end
            end
        end
    end
  end

  # --- Private: Tool call handling ---

  defp handle_tool_calls(messages, response, tool_calls, iter_config, middleware, metadata) do
    # Hook 3: before_tool_call
    ctx =
      Context.new(
        hook: :before_tool_call,
        messages: messages,
        response: response,
        tool_calls: tool_calls,
        config: iter_config,
        metadata: metadata
      )

    case Chain.run(middleware, ctx) do
      {:halt, reason} ->
        {:error, wrap_halt_reason(reason)}

      {:ok, ctx} ->
        approved_calls = ctx.tool_calls
        metadata = ctx.metadata

        # D14: If middleware filtered tool_calls, construct modified assistant message
        assistant_msg =
          if approved_calls == response.tool_calls do
            response
          else
            %{response | tool_calls: approved_calls}
          end

        messages = messages ++ [assistant_msg]
        context = build_tool_context(iter_config)
        {:ok, results} = ToolBroker.execute(approved_calls, iter_config.tools, context)

        # Hook 4: after_tool_call
        ctx =
          Context.new(
            hook: :after_tool_call,
            messages: messages,
            response: assistant_msg,
            tool_calls: approved_calls,
            tool_results: results,
            config: iter_config,
            metadata: metadata
          )

        case Chain.run(middleware, ctx) do
          {:halt, reason} ->
            {:error, wrap_halt_reason(reason)}

          {:ok, ctx} ->
            tool_msg = Message.tool_results(ctx.tool_results)
            new_messages = messages ++ [tool_msg]

            iter_facts = %{
              appended_messages: [assistant_msg, tool_msg],
              tool_calls_made: approved_calls,
              tool_results: ctx.tool_results
            }

            {:continue, new_messages, ctx.metadata, iter_facts}
        end
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

  # --- Private: Helpers ---

  defp merge_facts(facts, iter_facts) do
    %{
      facts
      | appended_messages: facts.appended_messages ++ Map.get(iter_facts, :appended_messages, []),
        tool_calls_made: facts.tool_calls_made ++ Map.get(iter_facts, :tool_calls_made, []),
        tool_results: facts.tool_results ++ Map.get(iter_facts, :tool_results, [])
    }
  end

  defp build_tool_context(config) do
    base = %{agent_name: config.name}

    case Keyword.get(config.provider_opts, :_agora_tool_depth) do
      nil -> base
      depth -> Map.put(base, :agora_tool_depth, depth)
    end
  end

  defp telemetry_metadata(%AgentConfig{} = config) do
    %{
      provider: config.provider,
      model: config.model,
      agent_name: config.name,
      max_iterations: config.max_iterations
    }
  end
end
