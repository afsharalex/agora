defmodule Agora.Middleware.MaxTokensTest do
  use ExUnit.Case, async: true

  alias Agora.Middleware.{Chain, Context, MaxTokens}
  alias Agora.{AgentConfig, Error, Message, ToolCall, ToolResult}

  defp sample_config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end

  defp context_for(hook, attrs \\ []) do
    defaults = [hook: hook, config: sample_config()]
    Context.new(Keyword.merge(defaults, attrs))
  end

  describe "under budget" do
    test "passes through and stores estimate in namespaced metadata" do
      # "hello" = 5 chars / 4 chars_per_token = ceil(5/4) = 2 tokens
      messages = [Message.user("hello")]
      mw = MaxTokens.new(max_tokens: 100)
      ctx = context_for(:before_provider_call, messages: messages)

      assert {:ok, result} = Chain.run([mw], ctx)
      assert result.metadata[MaxTokens][:estimated_tokens] == 2
    end
  end

  describe "over budget" do
    test "halts with :middleware_error" do
      # 400 chars / 4 = 100 tokens, budget is 50
      messages = [Message.user(String.duplicate("x", 400))]
      mw = MaxTokens.new(max_tokens: 50)
      ctx = context_for(:before_provider_call, messages: messages)

      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "Token budget exceeded"
      assert msg =~ "100"
      assert msg =~ "50"
    end
  end

  describe "custom chars_per_token" do
    test "uses custom ratio for estimation" do
      # 100 chars / 2 chars_per_token = 50 tokens
      messages = [Message.user(String.duplicate("x", 100))]
      mw = MaxTokens.new(max_tokens: 100, chars_per_token: 2)
      ctx = context_for(:before_provider_call, messages: messages)

      assert {:ok, result} = Chain.run([mw], ctx)
      assert result.metadata[MaxTokens][:estimated_tokens] == 50
    end
  end

  describe "chars_per_token validation" do
    test "rejects zero" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        MaxTokens.new(max_tokens: 100, chars_per_token: 0)
      end
    end

    test "rejects negative" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        MaxTokens.new(max_tokens: 100, chars_per_token: -1)
      end
    end

    test "rejects non-integer" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        MaxTokens.new(max_tokens: 100, chars_per_token: 2.5)
      end
    end
  end

  describe "hook selectivity" do
    test "only active at :before_provider_call" do
      # Would be over budget at :before_provider_call, but passes at other hooks
      messages = [Message.user(String.duplicate("x", 10_000))]
      mw = MaxTokens.new(max_tokens: 1)

      for hook <- [:after_provider_call, :before_tool_call, :after_tool_call] do
        ctx = context_for(hook, messages: messages)
        assert {:ok, _} = Chain.run([mw], ctx), "Expected passthrough at #{hook}"
      end
    end
  end

  describe "token estimation includes tool data" do
    test "includes tool_call arguments in estimate" do
      tool_call =
        ToolCall.new(%{
          id: "tc1",
          name: "search",
          arguments: %{"query" => String.duplicate("q", 100)}
        })

      messages = [Message.assistant(nil, [tool_call])]
      mw = MaxTokens.new(max_tokens: 1000)
      ctx = context_for(:before_provider_call, messages: messages)

      assert {:ok, result} = Chain.run([mw], ctx)
      # Name "search" (6 chars) + args JSON (~117 chars) = ~123 / 4 ≈ 30
      assert result.metadata[MaxTokens][:estimated_tokens] > 0
    end

    test "includes tool_result content in estimate" do
      results = [ToolResult.success("tc1", "search", String.duplicate("r", 200))]
      messages = [Message.tool_results(results)]
      mw = MaxTokens.new(max_tokens: 1000)
      ctx = context_for(:before_provider_call, messages: messages)

      assert {:ok, result} = Chain.run([mw], ctx)
      # 200 chars / 4 = 50 tokens
      assert result.metadata[MaxTokens][:estimated_tokens] == 50
    end
  end
end
