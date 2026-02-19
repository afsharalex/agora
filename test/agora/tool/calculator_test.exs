defmodule Agora.Tool.CalculatorTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.Calculator

  describe "name/0" do
    test "returns calculator" do
      assert Calculator.name() == "calculator"
    end
  end

  describe "description/0" do
    test "returns a description" do
      assert is_binary(Calculator.description())
    end
  end

  describe "schema/0" do
    test "returns a well-formed object schema" do
      schema = Calculator.schema()
      assert schema["type"] == "object"
      assert is_map(schema["properties"])
      assert "operation" in schema["required"]
      assert "a" in schema["required"]
      assert "b" in schema["required"]
    end
  end

  describe "execute/2" do
    test "add" do
      assert {:ok, 5} = Calculator.execute(%{"operation" => "add", "a" => 2, "b" => 3}, %{})
    end

    test "subtract" do
      assert {:ok, 7} = Calculator.execute(%{"operation" => "subtract", "a" => 10, "b" => 3}, %{})
    end

    test "multiply" do
      assert {:ok, 12} = Calculator.execute(%{"operation" => "multiply", "a" => 3, "b" => 4}, %{})
    end

    test "divide" do
      assert {:ok, 2.5} = Calculator.execute(%{"operation" => "divide", "a" => 5, "b" => 2}, %{})
    end

    test "divide by zero returns error" do
      assert {:error, "Division by zero"} =
               Calculator.execute(%{"operation" => "divide", "a" => 5, "b" => 0}, %{})
    end

    test "works with float operands" do
      assert {:ok, 5.5} = Calculator.execute(%{"operation" => "add", "a" => 2.5, "b" => 3.0}, %{})
    end
  end
end
