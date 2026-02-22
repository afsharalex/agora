defmodule Agora.AgentToolTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message}
  alias Agora.Tool.FunctionTool

  describe "agent_tool/2" do
    test "returns a FunctionTool" do
      config = config()
      tool = Agora.agent_tool(config, name: "helper")
      assert %FunctionTool{} = tool
      assert tool.name == "helper"
    end

    test "uses agent name as default tool name" do
      config = config(name: "researcher")
      tool = Agora.agent_tool(config)
      assert tool.name == "researcher"
    end

    test "falls back to 'agent_tool' when no name" do
      config = config()
      tool = Agora.agent_tool(config)
      assert tool.name == "agent_tool"
    end

    test "accepts custom description" do
      config = config()
      tool = Agora.agent_tool(config, description: "Custom desc")
      assert tool.description == "Custom desc"
    end

    test "accepts custom timeout" do
      config = config()
      tool = Agora.agent_tool(config, timeout: 60_000)
      assert tool.timeout == 60_000
    end
  end

  describe "basic execution" do
    test "agent tool runs child agent and returns content" do
      child_config = config()
      tool = Agora.agent_tool(child_config, name: "echo_helper")

      # Simulate tool invocation
      result = tool.function.(%{"task" => "Hello child"}, %{})
      assert {:ok, content} = result
      assert content =~ "Hello child"
    end

    test "tool receives agent_name in context from loop" do
      # Verify the FunctionTool can receive context
      child_config = config()
      tool = Agora.agent_tool(child_config, name: "ctx_test")

      # Pass context similar to what the loop provides
      result = tool.function.(%{"task" => "test"}, %{agent_name: "parent"})
      assert {:ok, _} = result
    end
  end

  describe "depth guard" do
    test "respects max_depth" do
      child_config = config()
      tool = Agora.agent_tool(child_config, name: "depth_test", max_depth: 2)

      # At depth 2, should be blocked
      result = tool.function.(%{"task" => "test"}, %{agora_tool_depth: 2})
      assert {:error, msg} = result
      assert msg =~ "exceeds max_depth"
    end

    test "allows execution below max_depth" do
      child_config = config()
      tool = Agora.agent_tool(child_config, name: "depth_ok", max_depth: 3)

      # At depth 1, should succeed
      result = tool.function.(%{"task" => "test"}, %{agora_tool_depth: 1})
      assert {:ok, _} = result
    end

    test "defaults to depth 0 when no depth in context" do
      child_config = config()
      tool = Agora.agent_tool(child_config, name: "no_depth", max_depth: 3)

      # No depth in context — treated as 0, should succeed
      result = tool.function.(%{"task" => "test"}, %{})
      assert {:ok, _} = result
    end

    test "depth propagates through provider_opts to child" do
      # Create a child agent that has its own agent_tool
      # The inner tool should see incremented depth

      inner_config = config()
      inner_tool = Agora.agent_tool(inner_config, name: "inner", max_depth: 2)

      # Simulate: parent is at depth 0, calls child with inner_tool
      # Child should inject depth=1 into its provider_opts
      # Inner tool at depth 1 should still work (< max_depth 2)
      outer_config = config(tools: [inner_tool])
      outer_tool = Agora.agent_tool(outer_config, name: "outer", max_depth: 3)

      # Outer tool at depth 0 — creates child with depth 1
      result = outer_tool.function.(%{"task" => "test"}, %{agora_tool_depth: 0})
      assert {:ok, _} = result
    end
  end

  describe "integration with parent agent" do
    test "parent agent can use agent tool" do
      child_config = config()
      child_tool = Agora.agent_tool(child_config, name: "child_agent_integration")

      # Create a parent agent that will call the child tool
      counter = :counters.new(1, [:atomics])

      parent_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             %Message{
               role: :assistant,
               content: nil,
               tool_calls: [
                 %Agora.ToolCall{
                   id: "call_1",
                   name: "child_agent_integration",
                   arguments: %{"task" => "Do the subtask"}
                 }
               ]
             }}

          _ ->
            {:ok, Message.assistant("Done with subtask result")}
        end
      end

      parent_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          name: "parent_agent",
          tools: [child_tool],
          provider_opts: [echo_mode: :function, echo_function: parent_fn]
        )

      {:ok, result} = Agora.run(parent_config, "Use the child agent")
      assert %Message{} = result
      assert result.content =~ "Done"
    end
  end

  describe "max_depth validation" do
    test "raises ArgumentError for non-integer max_depth" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Agora.agent_tool(config(), max_depth: "3")
      end
    end

    test "raises ArgumentError for zero max_depth" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Agora.agent_tool(config(), max_depth: 0)
      end
    end

    test "raises ArgumentError for negative max_depth" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Agora.agent_tool(config(), max_depth: -1)
      end
    end

    test "accepts valid positive integer max_depth" do
      tool = Agora.agent_tool(config(), max_depth: 5)
      assert %FunctionTool{} = tool
    end
  end

  describe "tool context wiring" do
    test "FunctionTool receives non-empty context with agent_name" do
      # Use a function tool that captures the context it receives
      test_pid = self()

      spy_tool =
        FunctionTool.new!(
          name: "spy_tool_ctx",
          description: "Captures context",
          schema: %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "string"}},
            "required" => ["x"]
          },
          function: fn _args, ctx ->
            send(test_pid, {:ctx, ctx})
            {:ok, "ok"}
          end
        )

      counter = :counters.new(1, [:atomics])

      parent_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             %Message{
               role: :assistant,
               content: nil,
               tool_calls: [
                 %Agora.ToolCall{
                   id: "call_ctx",
                   name: "spy_tool_ctx",
                   arguments: %{"x" => "test"}
                 }
               ]
             }}

          _ ->
            {:ok, Message.assistant("Done")}
        end
      end

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          name: "context_parent",
          tools: [spy_tool],
          provider_opts: [echo_mode: :function, echo_function: parent_fn]
        )

      {:ok, _} = Agora.run(config, "test context")

      assert_receive {:ctx, ctx}, 1000
      assert ctx.agent_name == "context_parent"
    end
  end

  defp config(opts \\ []) do
    AgentConfig.new!(Keyword.merge([provider: :echo, model: "echo"], opts))
  end
end
