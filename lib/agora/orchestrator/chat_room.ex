defmodule Agora.Orchestrator.ChatRoom do
  @moduledoc """
  Shared-context orchestrator where all agents take turns seeing the full transcript.

  Each agent receives the accumulated transcript of all previous turns as a user
  message. This enables collaborative discussion patterns.

  ## Config

    * `config.agent_names` (required) — list of agent name atoms
    * `config.agent_order` (optional) — explicit turn order; defaults to sorted `agent_names`
    * `config.max_transcript_messages` (optional) — cap on transcript entries to
      bound O(n^2) token growth. `nil` (default) means no limit.

  """

  @behaviour Agora.Orchestrator

  alias Agora.{Error, Message}

  @impl true
  def init(config) do
    order = Map.get(config, :agent_order) || Enum.sort(config.agent_names)
    max = Map.get(config, :max_transcript_messages)

    if order == [] do
      {:error, Error.new(:orchestration_error, "ChatRoom requires at least one agent")}
    else
      {:ok,
       %{
         order: order,
         index: 0,
         transcript: [],
         max_transcript_messages: max
       }}
    end
  end

  @impl true
  def next(%{order: order, index: index} = state, context) do
    agent = Enum.at(order, rem(index, length(order)))

    input =
      case state.transcript do
        [] ->
          context.original_input

        transcript ->
          entries = maybe_truncate(transcript, state.max_transcript_messages)

          text =
            entries
            |> Enum.map(fn %{speaker: speaker, content: content} ->
              "[#{speaker}]: #{content}"
            end)
            |> Enum.join("\n\n")

          Message.user(text)
      end

    {:next, agent, input, %{state | index: index + 1}}
  end

  @impl true
  def handle_result(state, agent, {:ok, msg}) do
    entry = %{speaker: agent, content: msg.content || ""}
    {:continue, %{state | transcript: state.transcript ++ [entry]}}
  end

  def handle_result(state, _agent, {:error, err}) do
    {:error, err, state}
  end

  defp maybe_truncate(transcript, nil), do: transcript

  defp maybe_truncate(transcript, max) when length(transcript) > max do
    Enum.take(transcript, -max)
  end

  defp maybe_truncate(transcript, _max), do: transcript
end
