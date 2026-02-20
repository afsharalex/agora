defmodule Agora.Provider.SSE do
  @moduledoc """
  Server-Sent Events (SSE) line parser with partial-data buffering.

  Parses SSE-formatted text into structured event maps. Handles incremental
  data delivery by buffering incomplete events across `parse/2` calls.

  ## SSE Format

  Events are separated by blank lines (`\\n\\n`). Each event block contains
  field lines (`event:`, `data:`, `id:`) and optional comment lines (`:` prefix).
  Multiple `data:` lines within a block are joined with `\\n`.
  """

  @type sse_event :: %{event: String.t() | nil, data: String.t(), id: String.t() | nil}
  @type state :: %{buffer: String.t()}

  @doc "Creates a new parser state."
  @spec new() :: state()
  def new, do: %{buffer: ""}

  @doc """
  Parses new data, returning completed SSE events and updated state.

  Concatenates incoming data with any buffered partial data, splits on
  double-newline boundaries, and parses complete event blocks. The trailing
  incomplete segment is buffered for the next call.

  ## Examples

      iex> state = Agora.Provider.SSE.new()
      iex> {events, _state} = Agora.Provider.SSE.parse(state, "data: hello\\n\\n")
      iex> [%{data: "hello"}] = events

  """
  @spec parse(state(), binary()) :: {[sse_event()], state()}
  def parse(state, new_data) when is_binary(new_data) do
    combined = state.buffer <> new_data
    normalized = normalize_line_endings(combined)

    case String.split(normalized, "\n\n") do
      [incomplete] ->
        {[], %{buffer: incomplete}}

      parts ->
        {complete_blocks, [trailing]} = Enum.split(parts, -1)

        events =
          complete_blocks
          |> Enum.map(&parse_block/1)
          |> Enum.reject(&is_nil/1)

        {events, %{buffer: trailing}}
    end
  end

  @doc """
  Flushes any remaining buffered data as a final event.

  Call this when the stream ends to parse any trailing data that wasn't
  terminated with a double newline.
  """
  @spec flush(state()) :: {[sse_event()], state()}
  def flush(%{buffer: ""} = state), do: {[], state}

  def flush(%{buffer: buffer}) do
    case parse_block(buffer) do
      nil -> {[], %{buffer: ""}}
      event -> {[event], %{buffer: ""}}
    end
  end

  # --- Private ---

  defp normalize_line_endings(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp parse_block(block) do
    lines = String.split(block, "\n")

    result =
      Enum.reduce(lines, %{event: nil, data_parts: [], id: nil}, fn line, acc ->
        parse_field(String.trim_leading(line), acc)
      end)

    case result.data_parts do
      [] -> nil
      parts -> %{event: result.event, data: Enum.join(parts, "\n"), id: result.id}
    end
  end

  defp parse_field(":" <> _rest, acc), do: acc

  defp parse_field("event:" <> rest, acc) do
    %{acc | event: String.trim_leading(rest)}
  end

  defp parse_field("data:" <> rest, acc) do
    %{acc | data_parts: acc.data_parts ++ [String.trim_leading(rest)]}
  end

  defp parse_field("id:" <> rest, acc) do
    %{acc | id: String.trim_leading(rest)}
  end

  defp parse_field("", acc), do: acc
  defp parse_field(_unknown, acc), do: acc
end
