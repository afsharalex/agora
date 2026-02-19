defmodule Agora.Tool.Calculator do
  @moduledoc """
  Example tool that performs basic arithmetic operations.

  Supports add, subtract, multiply, and divide operations on two numbers.
  """

  @behaviour Agora.Tool

  alias Agora.Tool.Schema

  @impl true
  def name, do: "calculator"

  @impl true
  def description, do: "Performs basic arithmetic: add, subtract, multiply, divide"

  @impl true
  def schema do
    Schema.object(
      %{
        "operation" =>
          Schema.enum(["add", "subtract", "multiply", "divide"],
            description: "The arithmetic operation to perform"
          ),
        "a" => Schema.number(description: "First operand"),
        "b" => Schema.number(description: "Second operand")
      },
      required: ["operation", "a", "b"]
    )
  end

  @impl true
  def execute(%{"operation" => op, "a" => a, "b" => b}, _context) do
    case op do
      "add" -> {:ok, a + b}
      "subtract" -> {:ok, a - b}
      "multiply" -> {:ok, a * b}
      "divide" when b == 0 -> {:error, "Division by zero"}
      "divide" -> {:ok, a / b}
    end
  end
end
