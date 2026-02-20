defmodule Agora.Provider.StreamAccumulator do
  @moduledoc """
  Accumulates streaming deltas into a complete `Message.t()`.

  Processes `StreamEvent` structs as they arrive, building up text content
  and tool call data incrementally. When the stream is complete, `to_message/1`
  constructs the final `Message` struct.
  """

  alias Agora.{Message, StreamEvent, ToolCall}

  @type t :: %__MODULE__{
          content: String.t(),
          tool_calls: %{
            non_neg_integer() => %{id: String.t(), name: String.t(), arguments: String.t()}
          },
          metadata: map()
        }

  defstruct content: "", tool_calls: %{}, metadata: %{}

  @doc "Creates a new empty accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Applies a stream event to the accumulator, updating its state.

  Only processes `:text_delta`, `:tool_call_start`, and `:tool_call_delta`
  events. Other event types are ignored.
  """
  @spec apply(t(), StreamEvent.t()) :: t()
  def apply(acc, %StreamEvent{type: :text_delta, data: %{text: text}}) do
    %{acc | content: acc.content <> text}
  end

  def apply(acc, %StreamEvent{type: :tool_call_start, data: data}) do
    entry = %{id: data.id, name: data.name, arguments: ""}
    %{acc | tool_calls: Map.put(acc.tool_calls, data.index, entry)}
  end

  def apply(acc, %StreamEvent{type: :tool_call_delta, data: data}) do
    # Find tool call entry by id and append arguments fragment
    tool_calls =
      Enum.reduce(acc.tool_calls, acc.tool_calls, fn {index, entry}, tc_map ->
        if entry.id == data.id do
          Map.put(tc_map, index, %{entry | arguments: entry.arguments <> data.arguments_fragment})
        else
          tc_map
        end
      end)

    %{acc | tool_calls: tool_calls}
  end

  def apply(acc, _event), do: acc

  @doc """
  Builds a `Message.t()` from the accumulated state.

  Content is set to `nil` if the accumulated text is empty (matching the
  existing convention for tool-call-only assistant messages). Tool call
  argument strings are JSON-decoded into maps.
  """
  @spec to_message(t()) :: Message.t()
  def to_message(%__MODULE__{} = acc) do
    content = if acc.content == "", do: nil, else: acc.content

    tool_calls =
      acc.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, entry} ->
        arguments = decode_arguments(entry.arguments)

        ToolCall.new(%{
          id: entry.id,
          name: entry.name,
          arguments: arguments
        })
      end)

    msg = Message.assistant(content, tool_calls)

    if acc.metadata == %{} do
      msg
    else
      %{msg | metadata: acc.metadata}
    end
  end

  defp decode_arguments(""), do: %{}

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"_raw" => args}
    end
  end
end
