defmodule Agora.MessageTest do
  use ExUnit.Case, async: true

  alias Agora.{Message, ToolCall, ToolResult}

  describe "new/3" do
    test "creates a message with role and content" do
      msg = Message.new(:user, "Hello")

      assert msg.role == :user
      assert msg.content == "Hello"
      assert msg.tool_calls == []
      assert msg.tool_results == []
      assert msg.metadata == %{}
      assert %DateTime{} = msg.created_at
    end

    test "accepts nil content" do
      msg = Message.new(:assistant, nil)

      assert msg.content == nil
    end

    test "accepts options" do
      tc = ToolCall.new(%{id: "call_1", name: "search"})

      msg = Message.new(:assistant, "Let me search", tool_calls: [tc], metadata: %{model: "test"})

      assert length(msg.tool_calls) == 1
      assert msg.metadata == %{model: "test"}
    end
  end

  describe "system/1" do
    test "creates a system message" do
      msg = Message.system("You are helpful")

      assert msg.role == :system
      assert msg.content == "You are helpful"
    end
  end

  describe "user/1" do
    test "creates a user message" do
      msg = Message.user("What is Elixir?")

      assert msg.role == :user
      assert msg.content == "What is Elixir?"
    end
  end

  describe "assistant/2" do
    test "creates an assistant message with content" do
      msg = Message.assistant("Elixir is great")

      assert msg.role == :assistant
      assert msg.content == "Elixir is great"
      assert msg.tool_calls == []
    end

    test "creates an assistant message with tool calls and nil content" do
      tc = ToolCall.new(%{id: "call_1", name: "search"})
      msg = Message.assistant(nil, [tc])

      assert msg.role == :assistant
      assert msg.content == nil
      assert length(msg.tool_calls) == 1
    end
  end

  describe "tool/1" do
    test "creates a tool message from a result" do
      result = ToolResult.success("call_1", "search", "found it")
      msg = Message.tool(result)

      assert msg.role == :tool
      assert msg.content == "found it"
      assert length(msg.tool_results) == 1
    end
  end

  describe "tool_results/1" do
    test "creates a tool message from multiple results" do
      r1 = ToolResult.success("call_1", "search", "result 1")
      r2 = ToolResult.success("call_2", "fetch", "result 2")
      msg = Message.tool_results([r1, r2])

      assert msg.role == :tool
      assert msg.content == nil
      assert length(msg.tool_results) == 2
    end
  end

  describe "timestamp" do
    test "created_at is set at construction time" do
      before = DateTime.utc_now()
      msg = Message.user("test")
      after_time = DateTime.utc_now()

      assert DateTime.compare(msg.created_at, before) in [:gt, :eq]
      assert DateTime.compare(msg.created_at, after_time) in [:lt, :eq]
    end
  end

  describe "Jason encoding" do
    test "encodes a simple message to JSON" do
      msg = Message.user("Hello")
      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)

      assert decoded["role"] == "user"
      assert decoded["content"] == "Hello"
    end
  end
end
