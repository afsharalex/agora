defmodule Agora.Agent do
  @moduledoc """
  Public API for agent processes.

  Agents can be backed by either a GenServer (default) or a gen_statem
  state machine (when `config.lifecycle` is set).

  An agent receives user input, calls the LLM provider, detects tool calls,
  executes them via `ToolBroker`, feeds results back, and repeats until a final
  text response or iteration limit is reached.

  ## Middleware

  The reasoning loop supports middleware — composable interceptors at four
  hook points: `:before_provider_call`, `:after_provider_call`,
  `:before_tool_call`, and `:after_tool_call`. When `config.middleware` is
  empty, the loop runs with zero middleware overhead (no context construction).

  ## Concurrency

  `run/2` uses `GenServer.call` with `:infinity` timeout. The reasoning loop
  is spawned as a supervised task under `Agora.ToolSupervisor` and the
  GenServer blocks on `Task.yield(:infinity)`. This preserves the existing
  mailbox-queuing behavior where concurrent `run/2` calls queue behind each
  other (standard GenServer/gen_statem mailbox serialization). The iteration
  limit on the agent config bounds each individual run. `get_messages/1` and
  `get_status/1` also queue — they return accurate state between runs but are
  not observable during a run.

  ## Cancellation

  `run/3` and `stream_run/3` accept a `:cancel_token` option for two-tier
  cancellation. Soft cancel (`CancelToken.cancel/1`) is checked at loop
  boundaries. Hard kill (`CancelToken.kill/1`) terminates the spawned
  reasoning task immediately; the GenServer detects the kill via
  `Task.yield` and returns `{:error, %Error{type: :cancelled}}`.

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

  alias Agora.{Error, Message}

  @type status :: :idle | :running | :streaming

  @doc """
  Starts an agent process.

  Dispatches to `Agora.Agent.Server` (GenServer) by default, or
  `Agora.Agent.StateMachine` (gen_statem) when `config.lifecycle` is set.

  ## Options

    * `:config` (required) — an `%AgentConfig{}` struct
    * `:name` — optional process name registration

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {config, server_opts} = Keyword.pop!(opts, :config)

    if config.lifecycle do
      Agora.Agent.StateMachine.start_link(config, server_opts)
    else
      Agora.Agent.Server.start_link(config, server_opts)
    end
  end

  @doc """
  Sends a message to the agent and returns the final assistant response.

  Accepts a string (converted to a user message) or a `%Message{}` struct.
  Blocks until the reasoning loop completes. Concurrent calls queue behind
  each other due to GenServer serialization.

  ## Options

    * `:cancel_token` — `%CancelToken{}` for cooperative + hard-kill cancellation

  Returns `{:ok, %Message{}}` on success or `{:error, %Error{}}` on failure.
  """
  @spec run(GenServer.server(), String.t() | Message.t(), keyword()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def run(agent, input, opts \\ [])

  def run(agent, input, opts) when is_binary(input) do
    run(agent, Message.user(input), opts)
  end

  def run(agent, %Message{} = message, opts) do
    GenServer.call(agent, {:run, message, opts}, :infinity)
  end

  @doc """
  Sends a message and returns a stream of incremental events.

  Unlike `run/2`, this returns immediately with an `Agora.Stream` that the
  caller can enumerate to receive `StreamEvent` structs as the provider
  generates tokens. The GenServer remains responsive during streaming.

  ## Options

    * `:cancel_token` — `%CancelToken{}` for cooperative + hard-kill cancellation

  Returns `{:error, %Error{}}` if the agent is busy or the provider does
  not support streaming.
  """
  @spec stream_run(GenServer.server(), String.t() | Message.t(), keyword()) ::
          {:ok, Agora.Stream.t()} | {:error, Error.t()}
  def stream_run(agent, input, opts \\ [])

  def stream_run(agent, input, opts) when is_binary(input) do
    stream_run(agent, Message.user(input), opts)
  end

  def stream_run(agent, %Message{} = message, opts) do
    GenServer.call(agent, {:stream_run, message, opts}, :infinity)
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

  Note: because `run/2` blocks the GenServer (via `Task.yield`), this
  will always return `:idle` when called from an external process (calls
  queue behind any active run).
  """
  @spec get_status(GenServer.server()) :: status()
  def get_status(agent) do
    GenServer.call(agent, :get_status)
  end

  @doc """
  Returns the current lifecycle state for state machine agents.

  Returns `{:ok, state_name}` for StateMachine agents, or
  `{:error, %Error{}}` for Server (non-lifecycle) agents.
  """
  @spec get_lifecycle_state(GenServer.server()) :: {:ok, atom()} | {:error, Error.t()}
  def get_lifecycle_state(agent) do
    GenServer.call(agent, :get_lifecycle_state)
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

    if config.lifecycle do
      Agora.Agent.StateMachine.child_spec(opts)
    else
      Agora.Agent.Server.child_spec(opts)
    end
  end
end
