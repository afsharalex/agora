defmodule Agora.ToolResult do
  @moduledoc """
  Represents the result of executing a tool call.

  Content is always stored as a string for provider compatibility.
  Non-string content is automatically JSON-encoded.
  """

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t(),
          content: String.t(),
          is_error: boolean()
        }

  @derive Jason.Encoder
  defstruct [:tool_call_id, :name, :content, is_error: false]

  @doc """
  Creates a successful tool result.

  Non-string content is automatically JSON-encoded.

  ## Examples

      iex> Agora.ToolResult.success("call_1", "search", "found 3 results")
      %Agora.ToolResult{tool_call_id: "call_1", name: "search", content: "found 3 results", is_error: false}

      iex> Agora.ToolResult.success("call_1", "search", %{count: 3})
      %Agora.ToolResult{tool_call_id: "call_1", name: "search", content: ~s({"count":3}), is_error: false}

  """
  @spec success(String.t(), String.t(), term()) :: t()
  def success(tool_call_id, name, content) do
    %__MODULE__{
      tool_call_id: tool_call_id,
      name: name,
      content: encode_content(content),
      is_error: false
    }
  end

  @doc """
  Creates an error tool result.

  Non-string content is automatically JSON-encoded.

  ## Examples

      iex> Agora.ToolResult.error("call_1", "search", "connection timeout")
      %Agora.ToolResult{tool_call_id: "call_1", name: "search", content: "connection timeout", is_error: true}

  """
  @spec error(String.t(), String.t(), term()) :: t()
  def error(tool_call_id, name, content) do
    %__MODULE__{
      tool_call_id: tool_call_id,
      name: name,
      content: encode_content(content),
      is_error: true
    }
  end

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(content), do: Jason.encode!(content)
end
