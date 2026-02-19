defmodule Agora.ToolTest do
  use ExUnit.Case, async: true

  alias Agora.Tool
  alias Agora.Tool.FunctionTool

  defmodule DummyTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "dummy"

    @impl true
    def description, do: "A dummy tool for testing"

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context), do: {:ok, "dummy result"}
  end

  defmodule CustomTimeoutTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "custom_timeout"

    @impl true
    def description, do: "A tool with custom timeout"

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context), do: {:ok, "done"}

    @impl true
    def timeout, do: 5_000
  end

  defp function_tool do
    FunctionTool.new!(
      name: "inline",
      description: "An inline tool",
      schema: %{"type" => "object", "properties" => %{}},
      function: fn _args, _ctx -> {:ok, "inline result"} end
    )
  end

  describe "to_definition/1" do
    test "converts a module tool to definition map" do
      defn = Tool.to_definition(DummyTool)

      assert defn == %{
               "name" => "dummy",
               "description" => "A dummy tool for testing",
               "parameters" => %{"type" => "object", "properties" => %{}}
             }
    end

    test "converts a FunctionTool to definition map" do
      defn = Tool.to_definition(function_tool())

      assert defn == %{
               "name" => "inline",
               "description" => "An inline tool",
               "parameters" => %{"type" => "object", "properties" => %{}}
             }
    end
  end

  describe "resolve/2" do
    test "finds a module tool by name" do
      assert {:ok, DummyTool} = Tool.resolve("dummy", [DummyTool])
    end

    test "finds a FunctionTool by name" do
      ft = function_tool()
      assert {:ok, ^ft} = Tool.resolve("inline", [ft])
    end

    test "returns error for unknown tool" do
      assert {:error, %Agora.Error{type: :tool_error}} = Tool.resolve("nope", [DummyTool])
    end

    test "searches mixed tool list" do
      ft = function_tool()
      assert {:ok, DummyTool} = Tool.resolve("dummy", [ft, DummyTool])
      assert {:ok, ^ft} = Tool.resolve("inline", [ft, DummyTool])
    end
  end

  describe "execute/3" do
    test "dispatches to module execute callback" do
      assert {:ok, "dummy result"} = Tool.execute(DummyTool, %{}, %{})
    end

    test "dispatches to FunctionTool function" do
      ft = function_tool()
      assert {:ok, "inline result"} = Tool.execute(ft, %{}, %{})
    end

    test "passes args and context through" do
      ft =
        FunctionTool.new!(
          name: "echo",
          description: "echoes",
          schema: %{},
          function: fn args, ctx -> {:ok, {args, ctx}} end
        )

      assert {:ok, {%{"key" => "val"}, %{user: "alice"}}} =
               Tool.execute(ft, %{"key" => "val"}, %{user: "alice"})
    end
  end

  describe "timeout/1" do
    test "returns default 30_000 for module without timeout callback" do
      assert Tool.timeout(DummyTool) == 30_000
    end

    test "returns custom timeout from module callback" do
      assert Tool.timeout(CustomTimeoutTool) == 5_000
    end

    test "returns timeout from FunctionTool struct" do
      ft = function_tool()
      assert Tool.timeout(ft) == 30_000

      custom =
        FunctionTool.new!(
          name: "fast",
          description: "fast tool",
          schema: %{},
          function: fn _, _ -> {:ok, nil} end,
          timeout: 1_000
        )

      assert Tool.timeout(custom) == 1_000
    end
  end

  describe "tool_name/1" do
    test "returns name from module" do
      assert Tool.tool_name(DummyTool) == "dummy"
    end

    test "returns name from FunctionTool" do
      assert Tool.tool_name(function_tool()) == "inline"
    end
  end
end
