defmodule Agora.Tool.Regex do
  @moduledoc """
  Regular expression tool for matching, scanning, and replacing text.

  Supports three operations:
    * `match` — test if a pattern matches the input, returns the match or null
    * `scan` — find all matches in the input
    * `replace` — replace all matches with a replacement string

  ## Example

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.Regex]
      )

  """

  @behaviour Agora.Tool

  alias Agora.Tool.Schema

  @impl true
  def name, do: "regex"

  @impl true
  def description,
    do: "Match, scan, or replace text using regular expressions."

  @impl true
  def schema do
    Schema.object(
      %{
        "operation" =>
          Schema.enum(["match", "scan", "replace"],
            description: "The regex operation to perform"
          ),
        "pattern" => Schema.string(description: "The regular expression pattern"),
        "input" => Schema.string(description: "The text to process"),
        "replacement" =>
          Schema.string(description: "The replacement string (required for replace operation)")
      },
      required: ["operation", "pattern", "input"]
    )
  end

  @impl true
  def execute(
        %{"operation" => operation, "pattern" => pattern, "input" => input} = args,
        _context
      ) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        dispatch(operation, regex, input, args)

      {:error, {reason, _position}} ->
        {:error, "Invalid regex: #{reason}"}
    end
  end

  defp dispatch("match", regex, input, _args) do
    case Regex.run(regex, input) do
      nil -> {:ok, nil}
      matches -> {:ok, matches}
    end
  end

  defp dispatch("scan", regex, input, _args) do
    {:ok, Regex.scan(regex, input)}
  end

  defp dispatch("replace", regex, input, %{"replacement" => replacement}) do
    {:ok, Regex.replace(regex, input, replacement)}
  end

  defp dispatch("replace", _regex, _input, _args) do
    {:error, "The 'replacement' parameter is required for the replace operation"}
  end
end
