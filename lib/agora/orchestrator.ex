defmodule Agora.Orchestrator do
  @moduledoc """
  Behaviour for multi-agent orchestration strategies.

  An orchestrator controls *which* agent runs next and how messages route
  between agents, without modifying how agents work internally.

  ## Callbacks

    * `init/1` — initialize orchestrator state from config
    * `next/2` — decide which agent runs next and what input it receives
    * `handle_result/3` — process the result from an agent run

  ## Context

  The `next/2` callback receives a context map:

      %{
        original_input: Message.t(),
        history: [%{agent: atom(), input: Message.t(), output: result}]
      }

  This gives orchestrators visibility into which agent produced what,
  enabling different routing strategies (round-robin, delegation, etc.).

  ## Example

      defmodule MyOrchestrator do
        @behaviour Agora.Orchestrator

        @impl true
        def init(config), do: {:ok, %{agent: hd(config.agent_names)}}

        @impl true
        def next(state, context) do
          {:next, state.agent, context.original_input, state}
        end

        @impl true
        def handle_result(state, _agent, {:ok, msg}), do: {:done, msg, state}
        def handle_result(state, _agent, {:error, err}), do: {:error, err, state}
      end

  """

  alias Agora.{Error, Message}

  @type agent_name :: atom()

  @type turn :: %{
          agent: agent_name(),
          input: Message.t(),
          output: {:ok, Message.t()} | {:error, Error.t()}
        }

  @type context :: %{
          original_input: Message.t(),
          history: [turn()]
        }

  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, Error.t()}

  @callback next(state :: term(), context()) ::
              {:next, agent_name(), input :: Message.t(), new_state :: term()}
              | {:done, Message.t(), new_state :: term()}
              | {:error, Error.t(), new_state :: term()}

  @callback handle_result(
              state :: term(),
              agent_name(),
              {:ok, Message.t()} | {:error, Error.t()}
            ) ::
              {:continue, new_state :: term()}
              | {:continue, new_state :: term(), events :: [map()]}
              | {:done, Message.t(), new_state :: term()}
              | {:done, Message.t(), new_state :: term(), events :: [map()]}
              | {:error, Error.t(), new_state :: term()}
end
