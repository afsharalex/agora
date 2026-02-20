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

  alias Agora.{AgentConfig, Error, Message, Provider, ToolBroker}
  alias Agora.Middleware.{Chain, Context}

  @type status :: :idle | :running

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
  def init(%AgentConfig{} = config) do
    messages =
      if config.instructions != "" do
        [Message.system(config.instructions)]
      else
        []
      end

    {:ok,
     %{config: config, messages: messages, status: :idle, iteration: 0, middleware_metadata: %{}}}
  end

  @impl true
  def handle_call({:run, %Message{} = message}, _from, state) do
    state = %{state | status: :running, iteration: 0, middleware_metadata: %{}}
    messages = state.messages ++ [message]
    telemetry_meta = telemetry_metadata(state.config)

    :telemetry.execute(
      [:agora, :agent, :run, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    start_time = System.monotonic_time()

    {result, final_state} = safe_reasoning_loop(messages, state)

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

  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  # --- Private: Safe wrapper ---

  @messages_key :agora_agent_loop_messages

  defp safe_reasoning_loop(messages, state) do
    Process.put(@messages_key, messages)

    case reasoning_loop(messages, state) do
      {:ok, response, new_state} ->
        Process.delete(@messages_key)
        {{:ok, response}, new_state}

      {:error, error, new_state} ->
        Process.delete(@messages_key)
        {{:error, error}, new_state}
    end
  catch
    kind, reason ->
      recovered_messages = Process.delete(@messages_key) || messages

      error =
        Error.new(
          :unknown,
          format_crash(kind, reason),
          %{kind: to_string(kind), reason: format_crash_reason(reason)}
        )

      {{:error, error}, %{state | messages: recovered_messages}}
  end

  # --- Private: Reasoning Loop ---

  defp reasoning_loop(messages, %{iteration: iteration, config: config} = state) do
    Process.put(@messages_key, messages)

    if iteration >= config.max_iterations do
      error =
        Error.new(:iteration_limit, "Reached maximum iterations (#{config.max_iterations})", %{
          max_iterations: config.max_iterations,
          iterations: iteration
        })

      {:error, error, %{state | messages: messages}}
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

      case do_iteration(messages, config, middleware, state.middleware_metadata) do
        {:continue, new_messages, new_metadata} ->
          :telemetry.execute(
            [:agora, :agent, :loop_iteration, :stop],
            %{duration: System.monotonic_time() - iter_start},
            telemetry_meta |> Map.put(:iteration, iteration) |> Map.put(:has_tool_calls, true)
          )

          reasoning_loop(new_messages, %{
            state
            | messages: new_messages,
              middleware_metadata: new_metadata
          })

        {:done, response, new_messages} ->
          :telemetry.execute(
            [:agora, :agent, :loop_iteration, :stop],
            %{duration: System.monotonic_time() - iter_start},
            telemetry_meta |> Map.put(:iteration, iteration) |> Map.put(:has_tool_calls, false)
          )

          {:ok, response, %{state | messages: new_messages}}

        {:error, %Error{} = error} ->
          :telemetry.execute(
            [:agora, :agent, :loop_iteration, :stop],
            %{duration: System.monotonic_time() - iter_start},
            telemetry_meta |> Map.put(:iteration, iteration) |> Map.put(:error, error)
          )

          {:error, error, %{state | messages: messages}}
      end
    end
  end

  # --- Private: Iteration (fast path — no middleware) ---

  defp do_iteration(messages, config, [], _metadata) do
    case Provider.chat(config.provider, messages, config) do
      {:ok, %Message{tool_calls: tool_calls} = response} when tool_calls != [] ->
        messages = messages ++ [response]
        {:ok, results} = ToolBroker.execute(tool_calls, config.tools)
        tool_msg = Message.tool_results(results)
        messages = messages ++ [tool_msg]
        {:continue, messages, %{}}

      {:ok, %Message{} = response} ->
        messages = messages ++ [response]
        {:done, response, messages}

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
            # Hook 2: after_provider_call (unified — middleware decides tool-call flow)
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
                # Branch on middleware-modified tool_calls, not raw response
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
                  # Scrub stale tool_calls from response before persisting to history.
                  # Middleware may have cleared ctx.tool_calls without mutating ctx.response,
                  # leaving tool_calls on the assistant message with no corresponding :tool message.
                  final_response =
                    if ctx.response.tool_calls != [] do
                      %{ctx.response | tool_calls: []}
                    else
                      ctx.response
                    end

                  new_messages = iter_messages ++ [final_response]
                  {:done, final_response, new_messages}
                end
            end
        end
    end
  end

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
        {:ok, results} = ToolBroker.execute(approved_calls, iter_config.tools)

        # Hook 4: after_tool_call — receives filtered assistant_msg, not raw response
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
            {:continue, new_messages, ctx.metadata}
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
