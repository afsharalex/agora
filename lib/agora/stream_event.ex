defmodule Agora.StreamEvent do
  @moduledoc """
  Represents a single event in a streaming response.

  Stream events are emitted incrementally by providers during streaming and
  forwarded to callers via `Agora.Stream`. Each event has a `type` that
  determines the shape of its `data` field.

  ## Event Types

  | Type | Data | Description |
  |---|---|---|
  | `:text_delta` | `%{text: String.t()}` | Incremental text chunk |
  | `:tool_call_start` | `%{id: String.t(), name: String.t(), index: non_neg_integer()}` | Tool call begins |
  | `:tool_call_delta` | `%{id: String.t(), arguments_fragment: String.t()}` | Tool call JSON fragment |
  | `:tool_result` | `%ToolResult{}` | Tool execution result |
  | `:message_complete` | `%Message{}` | Accumulated complete message |
  | `:done` | `%{}` | Stream finished normally |
  | `:error` | `%Error{}` | Stream error |
  """

  alias Agora.{Error, Message, ToolResult}

  @type event_type ::
          :text_delta
          | :tool_call_start
          | :tool_call_delta
          | :tool_result
          | :message_complete
          | :done
          | :error

  @type t :: %__MODULE__{
          type: event_type(),
          data: term(),
          metadata: map()
        }

  @derive Jason.Encoder
  defstruct [:type, :data, metadata: %{}]

  @doc "Creates a text delta event."
  @spec text_delta(String.t(), map()) :: t()
  def text_delta(text, metadata \\ %{}) when is_binary(text) do
    %__MODULE__{type: :text_delta, data: %{text: text}, metadata: metadata}
  end

  @doc "Creates a tool call start event."
  @spec tool_call_start(String.t(), String.t(), non_neg_integer(), map()) :: t()
  def tool_call_start(id, name, index \\ 0, metadata \\ %{}) do
    %__MODULE__{
      type: :tool_call_start,
      data: %{id: id, name: name, index: index},
      metadata: metadata
    }
  end

  @doc "Creates a tool call delta event with a JSON argument fragment."
  @spec tool_call_delta(String.t(), String.t(), map()) :: t()
  def tool_call_delta(id, arguments_fragment, metadata \\ %{}) do
    %__MODULE__{
      type: :tool_call_delta,
      data: %{id: id, arguments_fragment: arguments_fragment},
      metadata: metadata
    }
  end

  @doc "Creates a tool result event."
  @spec tool_result(ToolResult.t(), map()) :: t()
  def tool_result(%ToolResult{} = result, metadata \\ %{}) do
    %__MODULE__{type: :tool_result, data: result, metadata: metadata}
  end

  @doc "Creates a message complete event with the accumulated message."
  @spec message_complete(Message.t(), map()) :: t()
  def message_complete(%Message{} = message, metadata \\ %{}) do
    %__MODULE__{type: :message_complete, data: message, metadata: metadata}
  end

  @doc "Creates a done event signaling stream completion."
  @spec done(map()) :: t()
  def done(metadata \\ %{}) do
    %__MODULE__{type: :done, data: %{}, metadata: metadata}
  end

  @doc "Creates an error event."
  @spec error(Error.t(), map()) :: t()
  def error(%Error{} = err, metadata \\ %{}) do
    %__MODULE__{type: :error, data: err, metadata: metadata}
  end
end
