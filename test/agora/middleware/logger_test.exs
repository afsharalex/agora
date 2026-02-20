defmodule Agora.Middleware.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Agora.Middleware.{Chain, Context, Logger}
  alias Agora.{AgentConfig, Message, ToolCall, ToolResult}

  defp sample_config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end

  defp context_for(hook, attrs \\ []) do
    defaults = [hook: hook, config: sample_config()]
    Context.new(Keyword.merge(defaults, attrs))
  end

  describe "before_provider_call" do
    test "logs message count and passes through" do
      messages = [Message.user("hello"), Message.user("world")]
      ctx = context_for(:before_provider_call, messages: messages)

      log =
        capture_log(fn ->
          assert {:ok, result} = Chain.run([Logger], ctx)
          assert result == ctx
        end)

      assert log =~ "before_provider_call"
      assert log =~ "2 messages"
    end
  end

  describe "after_provider_call" do
    test "logs response info and tool call count" do
      response = Message.assistant("hello there")
      tool_call = ToolCall.new(%{id: "tc1", name: "test_tool", arguments: %{}})

      ctx =
        context_for(:after_provider_call,
          response: response,
          tool_calls: [tool_call]
        )

      log =
        capture_log(fn ->
          assert {:ok, _} = Chain.run([Logger], ctx)
        end)

      assert log =~ "after_provider_call"
      assert log =~ "tool_calls=1"
    end
  end

  describe "before_tool_call" do
    test "logs tool names" do
      tool_calls = [
        ToolCall.new(%{id: "tc1", name: "add", arguments: %{}}),
        ToolCall.new(%{id: "tc2", name: "multiply", arguments: %{}})
      ]

      ctx = context_for(:before_tool_call, tool_calls: tool_calls)

      log =
        capture_log(fn ->
          assert {:ok, _} = Chain.run([Logger], ctx)
        end)

      assert log =~ "before_tool_call"
      assert log =~ "add"
      assert log =~ "multiply"
    end
  end

  describe "after_tool_call" do
    test "logs result count" do
      results = [
        ToolResult.success("tc1", "add", "3"),
        ToolResult.success("tc2", "mul", "12")
      ]

      ctx = context_for(:after_tool_call, tool_results: results)

      log =
        capture_log(fn ->
          assert {:ok, _} = Chain.run([Logger], ctx)
        end)

      assert log =~ "after_tool_call"
      assert log =~ "2 results"
    end
  end

  describe "passthrough behavior" do
    test "never halts" do
      for hook <- [
            :before_provider_call,
            :after_provider_call,
            :before_tool_call,
            :after_tool_call
          ] do
        ctx = context_for(hook)

        capture_log(fn ->
          assert {:ok, _} = Chain.run([Logger], ctx)
        end)
      end
    end
  end
end
