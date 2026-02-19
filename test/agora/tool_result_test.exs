defmodule Agora.ToolResultTest do
  use ExUnit.Case, async: true

  alias Agora.ToolResult

  describe "success/3" do
    test "creates a successful result with string content" do
      result = ToolResult.success("call_1", "search", "found 3 results")

      assert result.tool_call_id == "call_1"
      assert result.name == "search"
      assert result.content == "found 3 results"
      assert result.is_error == false
    end

    test "auto-encodes map content to JSON" do
      result = ToolResult.success("call_1", "search", %{count: 3})

      assert result.content == ~s({"count":3})
      assert result.is_error == false
    end

    test "auto-encodes list content to JSON" do
      result = ToolResult.success("call_1", "list", [1, 2, 3])

      assert result.content == "[1,2,3]"
    end
  end

  describe "error/3" do
    test "creates an error result with string content" do
      result = ToolResult.error("call_1", "search", "connection timeout")

      assert result.tool_call_id == "call_1"
      assert result.name == "search"
      assert result.content == "connection timeout"
      assert result.is_error == true
    end

    test "auto-encodes non-string error content" do
      result = ToolResult.error("call_1", "search", %{reason: :timeout})

      assert result.content == ~s({"reason":"timeout"})
      assert result.is_error == true
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      result = ToolResult.success("call_1", "search", "ok")
      json = Jason.encode!(result)
      decoded = Jason.decode!(json)

      assert decoded["tool_call_id"] == "call_1"
      assert decoded["name"] == "search"
      assert decoded["content"] == "ok"
      assert decoded["is_error"] == false
    end
  end
end
