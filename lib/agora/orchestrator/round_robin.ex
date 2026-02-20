defmodule Agora.Orchestrator.RoundRobin do
  @moduledoc """
  Cycles through agents in order, each receiving the previous agent's response.

  Never self-terminates — relies on external termination conditions
  (e.g., `max_turns`, `keyword_match`) to stop the cycle.

  ## Config

    * `config.agent_names` (required) — list of agent name atoms
    * `config.agent_order` (optional) — explicit ordering; defaults to sorted `agent_names`

  """

  @behaviour Agora.Orchestrator

  alias Agora.{Error, Message}

  @impl true
  def init(config) do
    order = Map.get(config, :agent_order) || Enum.sort(config.agent_names)

    if order == [] do
      {:error, Error.new(:orchestration_error, "RoundRobin requires at least one agent")}
    else
      {:ok, %{order: order, index: 0}}
    end
  end

  @impl true
  def next(%{order: order, index: index} = state, context) do
    agent = Enum.at(order, rem(index, length(order)))

    input =
      case context.history do
        [] ->
          context.original_input

        history ->
          last_turn = List.last(history)

          content =
            case last_turn.output do
              {:ok, msg} -> msg.content || ""
              {:error, _} -> ""
            end

          Message.user(content)
      end

    {:next, agent, input, %{state | index: index + 1}}
  end

  @impl true
  def handle_result(state, _agent, {:ok, _msg}) do
    {:continue, state}
  end

  def handle_result(state, _agent, {:error, err}) do
    {:error, err, state}
  end
end
