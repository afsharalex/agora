defmodule Agora.ToolCall do
  @moduledoc """
  Represents a tool invocation requested by a model.

  Tracks the lifecycle of a tool call from pending through completion or failure.
  """

  @type status :: :pending | :running | :completed | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          status: status()
        }

  @derive Jason.Encoder
  defstruct [:id, :name, arguments: %{}, status: :pending]

  @doc """
  Creates a new tool call struct.

  ## Examples

      iex> Agora.ToolCall.new(%{id: "call_1", name: "search", arguments: %{"q" => "elixir"}})
      %Agora.ToolCall{id: "call_1", name: "search", arguments: %{"q" => "elixir"}, status: :pending}

  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, Map.to_list(attrs))
  end
end
