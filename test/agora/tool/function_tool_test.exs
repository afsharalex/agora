defmodule Agora.Tool.FunctionToolTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.FunctionTool
  alias Agora.Error

  defp valid_opts do
    [
      name: "greet",
      description: "Greets a person",
      schema: %{"type" => "object", "properties" => %{}},
      function: fn _args, _ctx -> {:ok, "hello"} end
    ]
  end

  describe "new/1" do
    test "creates FunctionTool with valid opts" do
      assert {:ok, %FunctionTool{} = ft} = FunctionTool.new(valid_opts())
      assert ft.name == "greet"
      assert ft.description == "Greets a person"
      assert ft.schema == %{"type" => "object", "properties" => %{}}
      assert is_function(ft.function, 2)
      assert ft.timeout == 30_000
    end

    test "accepts custom timeout" do
      opts = Keyword.put(valid_opts(), :timeout, 5_000)
      assert {:ok, %FunctionTool{timeout: 5_000}} = FunctionTool.new(opts)
    end

    test "returns error for missing required fields" do
      assert {:error, %Error{type: :validation_error, message: msg}} = FunctionTool.new([])
      assert msg =~ "missing required fields"
    end

    test "returns error for missing name" do
      opts = Keyword.delete(valid_opts(), :name)
      assert {:error, %Error{type: :validation_error}} = FunctionTool.new(opts)
    end

    test "returns error for wrong name type" do
      opts = Keyword.put(valid_opts(), :name, 123)
      assert {:error, %Error{type: :validation_error, message: msg}} = FunctionTool.new(opts)
      assert msg =~ "name must be a string"
    end

    test "returns error for wrong function arity" do
      opts = Keyword.put(valid_opts(), :function, fn -> :nope end)
      assert {:error, %Error{type: :validation_error, message: msg}} = FunctionTool.new(opts)
      assert msg =~ "function must be a 2-arity function"
    end

    test "returns error for wrong schema type" do
      opts = Keyword.put(valid_opts(), :schema, "not a map")
      assert {:error, %Error{type: :validation_error, message: msg}} = FunctionTool.new(opts)
      assert msg =~ "schema must be a map"
    end

    test "returns error for invalid timeout" do
      opts = Keyword.put(valid_opts(), :timeout, -1)
      assert {:error, %Error{type: :validation_error, message: msg}} = FunctionTool.new(opts)
      assert msg =~ "timeout must be a positive integer"
    end
  end

  describe "new!/1" do
    test "returns FunctionTool on valid input" do
      ft = FunctionTool.new!(valid_opts())
      assert ft.name == "greet"
    end

    test "raises ArgumentError on invalid input" do
      assert_raise ArgumentError, fn ->
        FunctionTool.new!([])
      end
    end
  end

  describe "Jason encoding" do
    test "encodes without function field" do
      {:ok, ft} = FunctionTool.new(valid_opts())
      json = Jason.encode!(ft)
      decoded = Jason.decode!(json)

      assert decoded["name"] == "greet"
      assert decoded["description"] == "Greets a person"
      assert decoded["timeout"] == 30_000
      refute Map.has_key?(decoded, "function")
    end
  end
end
