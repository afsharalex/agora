defmodule Agora.ToolBrokerTest do
  use ExUnit.Case, async: true

  alias Agora.{ToolCall, ToolResult, ToolBroker}
  alias Agora.Tool.FunctionTool

  defmodule AddTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "add"

    @impl true
    def description, do: "Adds two numbers"

    @impl true
    def schema do
      Agora.Tool.Schema.object(
        %{
          "a" => Agora.Tool.Schema.number(),
          "b" => Agora.Tool.Schema.number()
        },
        required: ["a", "b"]
      )
    end

    @impl true
    def execute(%{"a" => a, "b" => b}, _ctx), do: {:ok, a + b}
  end

  defmodule ErrorTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "error_tool"

    @impl true
    def description, do: "Always errors"

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _ctx), do: {:error, "something went wrong"}
  end

  defmodule RaisingTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "raiser"

    @impl true
    def description, do: "Raises an exception"

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _ctx), do: raise("boom!")
  end

  defmodule ThrowingTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "thrower"

    @impl true
    def description, do: "Throws a value"

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _ctx), do: throw(:oops)
  end

  defmodule ExitingTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "exiter"

    @impl true
    def description, do: "Calls exit"

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _ctx), do: exit(:bye)
  end

  defmodule SlowTool do
    @behaviour Agora.Tool

    @impl true
    def name, do: "slow"

    @impl true
    def description, do: "A slow tool"

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _ctx) do
      Process.sleep(500)
      {:ok, "done"}
    end

    @impl true
    def timeout, do: 100
  end

  defp call(name, args \\ %{}, id \\ nil) do
    ToolCall.new(%{id: id || "call_#{name}", name: name, arguments: args})
  end

  describe "execute/4 - single tool" do
    test "successful execution" do
      tool_call = call("add", %{"a" => 1, "b" => 2})

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [AddTool])

      assert result.tool_call_id == "call_add"
      assert result.content == "3"
      assert result.is_error == false
    end
  end

  describe "execute/4 - parallel fan-out" do
    test "executes multiple tools in parallel" do
      inline =
        FunctionTool.new!(
          name: "greet",
          description: "greets",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:ok, "hello"} end
        )

      calls = [
        call("add", %{"a" => 10, "b" => 20}),
        call("greet")
      ]

      assert {:ok, results} = ToolBroker.execute(calls, [AddTool, inline])
      assert length(results) == 2
      assert Enum.any?(results, &(&1.content == "30"))
      assert Enum.any?(results, &(&1.content == "hello"))
    end
  end

  describe "execute/4 - unknown tool" do
    test "returns error result for unknown tool" do
      tool_call = call("nonexistent")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [AddTool])

      assert result.is_error == true
      assert result.content =~ "Unknown tool"
    end
  end

  describe "execute/4 - validation failure" do
    test "returns error result when args fail validation" do
      tool_call = call("add", %{"a" => "not_a_number", "b" => 2})

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [AddTool])

      assert result.is_error == true
      assert result.content =~ "Validation failed"
    end

    test "skips validation when validate: false" do
      tool_call = call("add", %{"a" => 1, "b" => 2})

      assert {:ok, [%ToolResult{is_error: false}]} =
               ToolBroker.execute([tool_call], [AddTool], %{}, validate: false)
    end
  end

  describe "execute/4 - tool returns error" do
    test "tool {:error, reason} becomes error result" do
      tool_call = call("error_tool")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [ErrorTool])

      assert result.is_error == true
      assert result.content == "something went wrong"
    end

    test "tool {:error, map} produces JSON-encoded error result without crashing" do
      map_error_tool =
        FunctionTool.new!(
          name: "map_error_tool",
          description: "returns a map error",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, _ctx -> {:error, %{code: 42, message: "boom"}} end
        )

      tool_call = call("map_error_tool")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [map_error_tool])

      assert result.is_error == true
      decoded = Jason.decode!(result.content)
      assert decoded["code"] == 42
      assert decoded["message"] == "boom"
    end
  end

  describe "execute/4 - tool raises exception" do
    test "caught exception becomes error result" do
      tool_call = call("raiser")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [RaisingTool])

      assert result.is_error == true
      assert result.content =~ "Tool raised"
      assert result.content =~ "boom!"
    end
  end

  describe "execute/4 - timeout" do
    test "timed out tool becomes error result" do
      tool_call = call("slow")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [SlowTool])

      assert result.is_error == true
      assert result.content =~ "timed out"
    end
  end

  describe "execute/4 - mixed results" do
    test "returns both success and error results" do
      calls = [
        call("add", %{"a" => 1, "b" => 2}, "ok_call"),
        call("error_tool", %{}, "err_call")
      ]

      assert {:ok, results} = ToolBroker.execute(calls, [AddTool, ErrorTool])
      assert length(results) == 2

      ok_result = Enum.find(results, &(&1.tool_call_id == "ok_call"))
      err_result = Enum.find(results, &(&1.tool_call_id == "err_call"))

      assert ok_result.is_error == false
      assert ok_result.content == "3"

      assert err_result.is_error == true
      assert err_result.content == "something went wrong"
    end
  end

  describe "execute/4 - context" do
    test "passes context map to tool execute" do
      ft =
        FunctionTool.new!(
          name: "ctx_reader",
          description: "reads context",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _args, ctx -> {:ok, ctx[:user]} end
        )

      tool_call = call("ctx_reader")

      assert {:ok, [%ToolResult{content: "alice", is_error: false}]} =
               ToolBroker.execute([tool_call], [ft], %{user: "alice"})
    end
  end

  describe "execute/4 - tool throws" do
    test "caught throw becomes error result" do
      tool_call = call("thrower")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [ThrowingTool])

      assert result.is_error == true
      assert result.content =~ "threw"
    end
  end

  describe "execute/4 - tool exits" do
    test "caught exit becomes error result" do
      tool_call = call("exiter")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [ExitingTool])

      assert result.is_error == true
      assert result.content =~ "exit"
    end
  end

  describe "execute/4 - plain map tools" do
    test "plain maps in tools list don't crash build_tool_map" do
      plain = %{"name" => "plain_tool", "description" => "a plain map tool", "parameters" => %{}}
      tool_call = call("plain_tool")

      # Plain maps can be resolved but can't be executed, so we get an error result
      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [plain])

      assert result.is_error == true
    end

    test "plain maps with atom keys don't crash build_tool_map" do
      plain = %{name: "atom_tool", description: "atom keys", parameters: %{}}
      tool_call = call("atom_tool")

      assert {:ok, [%ToolResult{} = result]} =
               ToolBroker.execute([tool_call], [plain])

      assert result.is_error == true
    end

    test "mixed executable and plain map tools work" do
      plain = %{"name" => "plain", "description" => "plain", "parameters" => %{}}

      calls = [
        call("add", %{"a" => 1, "b" => 2}, "ok_call"),
        call("plain", %{}, "plain_call")
      ]

      assert {:ok, results} = ToolBroker.execute(calls, [AddTool, plain])
      assert length(results) == 2

      ok_result = Enum.find(results, &(&1.tool_call_id == "ok_call"))
      plain_result = Enum.find(results, &(&1.tool_call_id == "plain_call"))

      assert ok_result.is_error == false
      assert ok_result.content == "3"
      assert plain_result.is_error == true
    end
  end

  describe "execute_single/4" do
    test "executes a single tool directly" do
      tool_call = call("add", %{"a" => 5, "b" => 3})
      tool_map = %{"add" => AddTool}

      result = ToolBroker.execute_single(tool_call, tool_map, %{}, true)

      assert result.is_error == false
      assert result.content == "8"
    end

    test "catches raised exceptions" do
      tool_call = call("raiser")
      tool_map = %{"raiser" => RaisingTool}

      result = ToolBroker.execute_single(tool_call, tool_map, %{}, false)

      assert result.is_error == true
      assert result.content =~ "boom!"
    end

    test "catches throws" do
      tool_call = call("thrower")
      tool_map = %{"thrower" => ThrowingTool}

      result = ToolBroker.execute_single(tool_call, tool_map, %{}, false)

      assert result.is_error == true
      assert result.content =~ "threw"
    end

    test "catches exits" do
      tool_call = call("exiter")
      tool_map = %{"exiter" => ExitingTool}

      result = ToolBroker.execute_single(tool_call, tool_map, %{}, false)

      assert result.is_error == true
      assert result.content =~ "exit"
    end
  end
end
