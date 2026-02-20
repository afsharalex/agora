defmodule Agora.Orchestrator.Single do
  @moduledoc """
  Trivial baseline orchestrator that runs a single agent once.

  Useful for wrapping a single agent in the orchestration framework,
  or as a starting point for custom orchestrators.

  ## Config

  Expects `config.agent_names` to contain at least one agent name.
  Uses the first agent in the list.
  """

  @behaviour Agora.Orchestrator

  alias Agora.Error

  @impl true
  def init(config) do
    case config do
      %{agent_names: [agent | _]} ->
        {:ok, %{agent: agent}}

      _ ->
        {:error,
         Error.new(:orchestration_error, "Single orchestrator requires at least one agent")}
    end
  end

  @impl true
  def next(state, context) do
    {:next, state.agent, context.original_input, state}
  end

  @impl true
  def handle_result(state, _agent, {:ok, msg}) do
    {:done, msg, state}
  end

  def handle_result(state, _agent, {:error, err}) do
    {:error, err, state}
  end
end
