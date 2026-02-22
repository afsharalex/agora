defmodule Agora.Tool.Think do
  @moduledoc """
  Reasoning scratchpad tool for structured thinking.

  Returns the agent's thought unchanged, forcing it into message history.
  This enables chain-of-thought reasoning visible in tool call records
  without affecting the final response.

  ## Example

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.Think]
      )

  """

  @behaviour Agora.Tool

  alias Agora.Tool.Schema

  @impl true
  def name, do: "think"

  @impl true
  def description,
    do:
      "Use this tool to think through a problem step-by-step. Your thought will be recorded but not shown to the user."

  @impl true
  def schema do
    Schema.object(
      %{
        "thought" => Schema.string(description: "Your step-by-step reasoning")
      },
      required: ["thought"]
    )
  end

  @impl true
  def execute(%{"thought" => thought}, _context) do
    {:ok, thought}
  end
end
