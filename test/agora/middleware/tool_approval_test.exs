defmodule Agora.Middleware.ToolApprovalTest do
  use ExUnit.Case, async: true

  alias Agora.Middleware.{Chain, Context, ToolApproval}
  alias Agora.{AgentConfig, Error, ToolCall}

  defp sample_config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end

  defp context_for(hook, attrs \\ []) do
    defaults = [hook: hook, config: sample_config()]
    Context.new(Keyword.merge(defaults, attrs))
  end

  defp sample_tool_calls do
    [
      ToolCall.new(%{id: "tc1", name: "safe_tool", arguments: %{}}),
      ToolCall.new(%{id: "tc2", name: "dangerous_tool", arguments: %{}})
    ]
  end

  describe "approve" do
    test ":approve passes through unchanged" do
      mw = ToolApproval.new(approve_fn: fn _calls -> :approve end)
      ctx = context_for(:before_tool_call, tool_calls: sample_tool_calls())

      assert {:ok, result} = Chain.run([mw], ctx)
      assert length(result.tool_calls) == 2
    end
  end

  describe "reject" do
    test "{:reject, reason} halts with :middleware_error" do
      mw = ToolApproval.new(approve_fn: fn _calls -> {:reject, "not allowed"} end)
      ctx = context_for(:before_tool_call, tool_calls: sample_tool_calls())

      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "rejected"
      assert msg =~ "not allowed"
    end
  end

  describe "filter" do
    test "{:filter, calls} modifies tool_calls in context" do
      safe_only = fn calls -> {:filter, Enum.filter(calls, &(&1.name == "safe_tool"))} end
      mw = ToolApproval.new(approve_fn: safe_only)
      ctx = context_for(:before_tool_call, tool_calls: sample_tool_calls())

      assert {:ok, result} = Chain.run([mw], ctx)
      assert length(result.tool_calls) == 1
      assert hd(result.tool_calls).name == "safe_tool"
    end

    test "{:filter, []} halts when all calls filtered out" do
      mw = ToolApproval.new(approve_fn: fn _calls -> {:filter, []} end)
      ctx = context_for(:before_tool_call, tool_calls: sample_tool_calls())

      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "All tool calls filtered out"
    end
  end

  describe "hook selectivity" do
    test "only active at :before_tool_call, passes through at other hooks" do
      reject_all = ToolApproval.new(approve_fn: fn _calls -> {:reject, "nope"} end)

      for hook <- [:before_provider_call, :after_provider_call, :after_tool_call] do
        ctx = context_for(hook, tool_calls: sample_tool_calls())
        assert {:ok, _} = Chain.run([reject_all], ctx), "Expected passthrough at #{hook}"
      end
    end
  end
end
