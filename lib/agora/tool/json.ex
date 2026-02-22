defmodule Agora.Tool.Json do
  @moduledoc """
  JSON processing tool for parsing, formatting, and querying JSON data.

  Supports three operations:
    * `parse` — validate and decode a JSON string
    * `format` — pretty-print a JSON string
    * `query` — extract a value using dot/bracket path notation (e.g. `"data.items[0].name"`)

  ## Example

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.Json]
      )

  """

  @behaviour Agora.Tool

  alias Agora.Tool.Schema

  @impl true
  def name, do: "json"

  @impl true
  def description,
    do:
      "Parse, format, or query JSON data. Use 'query' with a dot/bracket path to extract values."

  @impl true
  def schema do
    Schema.object(
      %{
        "operation" =>
          Schema.enum(["parse", "format", "query"],
            description: "The JSON operation to perform"
          ),
        "input" => Schema.string(description: "The JSON string to process"),
        "path" =>
          Schema.string(
            description:
              "Dot/bracket path for query operation (e.g. \"data.items[0].name\"). Required for query."
          )
      },
      required: ["operation", "input"]
    )
  end

  @impl true
  def execute(%{"operation" => "parse", "input" => input}, _context) do
    case Jason.decode(input) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{} = err} -> {:error, "Invalid JSON: #{Exception.message(err)}"}
    end
  end

  def execute(%{"operation" => "format", "input" => input}, _context) do
    case Jason.decode(input) do
      {:ok, decoded} ->
        case Jason.encode(decoded, pretty: true) do
          {:ok, formatted} -> {:ok, formatted}
          {:error, err} -> {:error, "Failed to format JSON: #{inspect(err)}"}
        end

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "Invalid JSON: #{Exception.message(err)}"}
    end
  end

  def execute(%{"operation" => "query", "input" => input, "path" => path}, _context) do
    case Jason.decode(input) do
      {:ok, decoded} ->
        case query_path(decoded, parse_path(path)) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "Invalid JSON: #{Exception.message(err)}"}
    end
  end

  def execute(%{"operation" => "query"}, _context) do
    {:error, "The 'path' parameter is required for the query operation"}
  end

  # Parse a dot/bracket path string into a list of access keys
  # e.g., "data.items[0].name" -> ["data", "items", 0, "name"]
  defp parse_path(path) do
    path
    |> String.split(~r/\.|\[|\]/, trim: true)
    |> Enum.map(fn segment ->
      case Integer.parse(segment) do
        {index, ""} -> index
        _ -> segment
      end
    end)
  end

  defp query_path(data, []), do: {:ok, data}

  defp query_path(data, [key | rest]) when is_map(data) and is_binary(key) do
    case Map.fetch(data, key) do
      {:ok, value} -> query_path(value, rest)
      :error -> {:error, "Key '#{key}' not found"}
    end
  end

  defp query_path(data, [index | rest]) when is_list(data) and is_integer(index) do
    if index >= 0 and index < length(data) do
      query_path(Enum.at(data, index), rest)
    else
      {:error, "Index #{index} out of bounds (list has #{length(data)} elements)"}
    end
  end

  defp query_path(_data, [key | _rest]) do
    {:error, "Cannot access '#{key}' on non-container value"}
  end
end
