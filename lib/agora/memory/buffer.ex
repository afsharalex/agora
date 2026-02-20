defmodule Agora.Memory.Buffer do
  @moduledoc """
  In-memory ring buffer memory backend.

  Keeps the last `:max_messages` messages using an Erlang `:queue`.
  When `save/2` is called, the entire buffer is replaced with the
  tail of the input list (bounded to `max_messages`).

  ## Configuration

    * `:max_messages` (required) — maximum number of messages to retain (`pos_integer()`)

  ## Example

      config = AgentConfig.new!(
        provider: :echo,
        model: "echo",
        memory: {Agora.Memory.Buffer, max_messages: 100}
      )

  """

  @behaviour Agora.Memory

  alias Agora.Error

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :max_messages) do
      {:ok, max} when is_integer(max) and max > 0 ->
        {:ok, %{queue: :queue.new(), max: max, size: 0}}

      {:ok, invalid} ->
        Error.wrap(
          :memory_error,
          ":max_messages must be a positive integer, got: #{inspect(invalid)}"
        )

      :error ->
        Error.wrap(:memory_error, ":max_messages is required for Buffer memory backend")
    end
  end

  @impl true
  def get(%{queue: queue}) do
    {:ok, :queue.to_list(queue)}
  end

  @impl true
  def save(state, messages) do
    len = length(messages)
    kept = Enum.drop(messages, max(0, len - state.max))
    kept_size = min(len, state.max)
    new_queue = :queue.from_list(kept)
    {:ok, %{state | queue: new_queue, size: kept_size}}
  end

  @impl true
  def clear(state) do
    {:ok, %{state | queue: :queue.new(), size: 0}}
  end
end
