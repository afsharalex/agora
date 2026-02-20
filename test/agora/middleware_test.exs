defmodule Agora.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Agora.Middleware.Context
  alias Agora.AgentConfig

  defp sample_config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end

  describe "Context.new/1" do
    test "creates struct with defaults" do
      ctx = Context.new(hook: :before_provider_call, config: sample_config())

      assert ctx.hook == :before_provider_call
      assert ctx.messages == []
      assert ctx.response == nil
      assert ctx.tool_calls == []
      assert ctx.tool_results == []
      assert ctx.metadata == %{}
      assert %AgentConfig{} = ctx.config
    end

    test "all fields are settable" do
      config = sample_config()
      response = Agora.Message.assistant("hello")
      tool_call = Agora.ToolCall.new(%{id: "tc1", name: "test", arguments: %{}})
      tool_result = Agora.ToolResult.success("tc1", "test", "ok")
      messages = [Agora.Message.user("hi")]

      ctx =
        Context.new(
          hook: :after_tool_call,
          messages: messages,
          response: response,
          tool_calls: [tool_call],
          tool_results: [tool_result],
          config: config,
          metadata: %{custom: "data"}
        )

      assert ctx.hook == :after_tool_call
      assert ctx.messages == messages
      assert ctx.response == response
      assert ctx.tool_calls == [tool_call]
      assert ctx.tool_results == [tool_result]
      assert ctx.metadata == %{custom: "data"}
    end

    test "raises on unknown keys" do
      assert_raise KeyError, fn ->
        Context.new(hook: :before_provider_call, config: sample_config(), unknown_key: true)
      end
    end
  end
end
