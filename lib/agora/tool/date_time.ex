defmodule Agora.Tool.DateTime do
  @moduledoc """
  Example tool that returns the current date and/or time.

  Supports three formats: "date", "time", and "datetime".
  """

  @behaviour Agora.Tool

  alias Agora.Tool.Schema

  @impl true
  def name, do: "current_datetime"

  @impl true
  def description, do: "Returns the current date and/or time in UTC"

  @impl true
  def schema do
    Schema.object(
      %{
        "format" =>
          Schema.enum(["date", "time", "datetime"],
            description: "Output format: date, time, or datetime"
          )
      },
      required: ["format"]
    )
  end

  @impl true
  def execute(%{"format" => format}, _context) do
    now = Elixir.DateTime.utc_now()

    case format do
      "date" ->
        {:ok, Calendar.strftime(now, "%Y-%m-%d")}

      "time" ->
        {:ok, Calendar.strftime(now, "%H:%M:%S")}

      "datetime" ->
        {:ok, Elixir.DateTime.to_iso8601(now)}

      other ->
        {:error, "Unknown format: #{other}"}
    end
  end
end
