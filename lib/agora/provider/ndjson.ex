defmodule Agora.Provider.NDJSON do
  @moduledoc """
  Newline-Delimited JSON (NDJSON) parser with partial-line buffering.

  Parses NDJSON-formatted text into decoded JSON maps. Handles incremental
  data delivery by buffering incomplete lines across `parse/2` calls.

  Used by the Ollama provider, which streams responses as NDJSON rather than SSE.
  """

  @type state :: %{buffer: String.t()}

  @doc "Creates a new parser state."
  @spec new() :: state()
  def new, do: %{buffer: ""}

  @doc """
  Parses new data, returning decoded JSON objects and updated state.

  Concatenates incoming data with any buffered partial data, splits on
  newline boundaries, and decodes complete JSON lines. The trailing
  incomplete segment is buffered for the next call. Malformed JSON lines
  are silently dropped.

  ## Examples

      iex> state = Agora.Provider.NDJSON.new()
      iex> {events, _state} = Agora.Provider.NDJSON.parse(state, ~s({"done":false}\\n))
      iex> [%{"done" => false}] = events

  """
  @spec parse(state(), binary()) :: {[map()], state()}
  def parse(state, new_data) when is_binary(new_data) do
    combined = state.buffer <> new_data
    normalized = normalize_line_endings(combined)

    case String.split(normalized, "\n") do
      [incomplete] ->
        {[], %{buffer: incomplete}}

      parts ->
        {complete_lines, [trailing]} = Enum.split(parts, -1)

        events =
          complete_lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, decoded} when is_map(decoded) -> [decoded]
              _ -> []
            end
          end)

        {events, %{buffer: trailing}}
    end
  end

  @doc """
  Flushes any remaining buffered data as a final event.

  Call this when the stream ends to parse any trailing data that wasn't
  terminated with a newline.
  """
  @spec flush(state()) :: {[map()], state()}
  def flush(%{buffer: ""} = state), do: {[], state}

  def flush(%{buffer: buffer}) do
    case Jason.decode(buffer) do
      {:ok, decoded} when is_map(decoded) -> {[decoded], %{buffer: ""}}
      _ -> {[], %{buffer: ""}}
    end
  end

  defp normalize_line_endings(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end
end
