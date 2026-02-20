defmodule Agora.Middleware.TimeoutTest do
  use ExUnit.Case, async: true

  alias Agora.Middleware.{Chain, Context, Timeout}
  alias Agora.{AgentConfig, Error}

  defp sample_config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end

  defp context_for(hook, attrs \\ []) do
    defaults = [hook: hook, config: sample_config()]
    Context.new(Keyword.merge(defaults, attrs))
  end

  describe "before deadline" do
    test "passes through and stores deadline in namespaced metadata" do
      mw = Timeout.new(timeout_ms: 60_000)
      ctx = context_for(:before_provider_call)

      assert {:ok, result} = Chain.run([mw], ctx)
      assert is_integer(result.metadata[Timeout][:deadline])
    end
  end

  describe "after deadline" do
    test "halts with :timeout error on subsequent invocation" do
      # First invocation sets deadline at now + 0ms
      mw = Timeout.new(timeout_ms: 0)
      ctx = context_for(:before_provider_call)
      assert {:ok, result} = Chain.run([mw], ctx)

      # Sleep so time advances past the deadline
      Process.sleep(1)

      # Second invocation with persisted metadata should see expired deadline
      ctx2 = context_for(:after_provider_call, metadata: result.metadata)
      assert {:halt, %Error{type: :timeout, message: msg}} = Chain.run([mw], ctx2)
      assert msg =~ "timeout exceeded"
    end
  end

  describe "deadline reuse" do
    test "deadline set on first invocation, reused on subsequent calls" do
      mw = Timeout.new(timeout_ms: 60_000)
      ctx = context_for(:before_provider_call)

      assert {:ok, result1} = Chain.run([mw], ctx)
      deadline1 = result1.metadata[Timeout][:deadline]

      # Second call with metadata from first
      ctx2 = context_for(:after_provider_call, metadata: result1.metadata)
      assert {:ok, result2} = Chain.run([mw], ctx2)
      deadline2 = result2.metadata[Timeout][:deadline]

      assert deadline1 == deadline2
    end

    test "metadata carries deadline across hook invocations" do
      mw = Timeout.new(timeout_ms: 60_000)

      ctx1 = context_for(:before_provider_call)
      assert {:ok, r1} = Chain.run([mw], ctx1)

      ctx2 = context_for(:after_provider_call, metadata: r1.metadata)
      assert {:ok, r2} = Chain.run([mw], ctx2)

      ctx3 = context_for(:before_tool_call, metadata: r2.metadata)
      assert {:ok, r3} = Chain.run([mw], ctx3)

      ctx4 = context_for(:after_tool_call, metadata: r3.metadata)
      assert {:ok, r4} = Chain.run([mw], ctx4)

      # All share same deadline
      assert r1.metadata[Timeout][:deadline] == r4.metadata[Timeout][:deadline]
    end
  end

  describe "hook coverage" do
    test "active at all hooks" do
      mw = Timeout.new(timeout_ms: 60_000)

      for hook <- [
            :before_provider_call,
            :after_provider_call,
            :before_tool_call,
            :after_tool_call
          ] do
        ctx = context_for(hook)
        assert {:ok, result} = Chain.run([mw], ctx)
        assert result.metadata[Timeout][:deadline], "Expected deadline at #{hook}"
      end
    end
  end
end
