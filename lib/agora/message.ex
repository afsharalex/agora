defmodule Agora.Message do
  @moduledoc """
  Represents a message in a conversation.

  Messages form the conversation history that is sent to providers.
  The `content` field is nilable to support assistant messages that
  contain only tool calls.
  """

  alias Agora.{ToolCall, ToolResult}

  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | nil,
          tool_calls: [ToolCall.t()],
          tool_results: [ToolResult.t()],
          metadata: map(),
          created_at: DateTime.t()
        }

  @derive Jason.Encoder
  defstruct [:role, :content, :created_at, tool_calls: [], tool_results: [], metadata: %{}]

  @doc """
  Creates a new message with the given role, content, and options.

  ## Options

    * `:tool_calls` - list of tool calls (default: `[]`)
    * `:tool_results` - list of tool results (default: `[]`)
    * `:metadata` - arbitrary metadata map (default: `%{}`)

  ## Examples

      iex> msg = Agora.Message.new(:user, "Hello")
      iex> msg.role
      :user
      iex> msg.content
      "Hello"

  """
  @spec new(role(), String.t() | nil, keyword()) :: t()
  def new(role, content, opts \\ []) when role in [:system, :user, :assistant, :tool] do
    %__MODULE__{
      role: role,
      content: content,
      tool_calls: Keyword.get(opts, :tool_calls, []),
      tool_results: Keyword.get(opts, :tool_results, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: DateTime.utc_now()
    }
  end

  @doc "Creates a system message."
  @spec system(String.t()) :: t()
  def system(content) when is_binary(content), do: new(:system, content)

  @doc "Creates a user message."
  @spec user(String.t()) :: t()
  def user(content) when is_binary(content), do: new(:user, content)

  @doc """
  Creates an assistant message.

  ## Examples

      iex> msg = Agora.Message.assistant("I'll help with that.", [])
      iex> msg.role
      :assistant

  """
  @spec assistant(String.t() | nil, [ToolCall.t()]) :: t()
  def assistant(content, tool_calls \\ []) do
    new(:assistant, content, tool_calls: tool_calls)
  end

  @doc "Creates a tool message from a single tool result."
  @spec tool(ToolResult.t()) :: t()
  def tool(%ToolResult{} = result) do
    new(:tool, result.content, tool_results: [result])
  end

  @doc "Creates a tool message from multiple tool results."
  @spec tool_results([ToolResult.t()]) :: t()
  def tool_results(results) when is_list(results) do
    new(:tool, nil, tool_results: results)
  end
end
