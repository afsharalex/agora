defmodule Agora.AgentToolCancelTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, AgentTool, CancelToken, Error, Message}
  alias Agora.ToolCall

  defp echo_config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [provider: :echo, model: "echo", name: "agent_tool_cancel"],
        opts
      )
    )
  end

  describe "cancel token propagation" do
    test "cancel_token from tool context is passed to child agent" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      child_config = echo_config()
      tool = AgentTool.new(child_config, name: "child_agent")

      # Simulate tool execution with cancel_token in context
      ctx = %{cancel_token: token, agora_tool_depth: 0}
      result = tool.function.(%{"task" => "Hello"}, ctx)

      # Should propagate cancel to child and get cancelled error
      assert {:error, msg} = result
      assert msg =~ "cancelled"
    end

    test "no cancel_token in context works normally" do
      child_config = echo_config()
      tool = AgentTool.new(child_config, name: "child_agent")

      ctx = %{agora_tool_depth: 0}
      result = tool.function.(%{"task" => "Hello"}, ctx)

      assert {:ok, content} = result
      assert content =~ "Hello"
    end

    test "nil cancel_token in context is handled" do
      child_config = echo_config()
      tool = AgentTool.new(child_config, name: "child_agent")

      ctx = %{cancel_token: nil, agora_tool_depth: 0}
      result = tool.function.(%{"task" => "Hello"}, ctx)

      assert {:ok, content} = result
      assert content =~ "Hello"
    end
  end

  describe "cancel token through full agent loop" do
    test "parent agent tool execution propagates cancel to child" do
      token = CancelToken.new()

      # Create a child config that will be wrapped as a tool
      child_config =
        echo_config(
          name: "child",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _msgs, _config ->
              # Simulate some work, check cancel during
              Process.sleep(10)
              {:ok, Message.assistant("child result")}
            end
          ]
        )

      child_tool = AgentTool.new(child_config, name: "child_agent")

      # Create parent agent that uses the child as a tool
      parent_config =
        echo_config(
          name: "parent",
          tools: [child_tool],
          max_iterations: 3,
          provider_opts: [
            echo_mode: :function,
            echo_function: fn msgs, _config ->
              if length(msgs) <= 2 do
                call =
                  ToolCall.new(%{
                    id: "c1",
                    name: "child_agent",
                    arguments: %{"task" => "Do something"}
                  })

                {:ok, Message.assistant(nil, [call])}
              else
                {:ok, Message.assistant("parent done")}
              end
            end
          ]
        )

      # Run without cancel — should work
      assert {:ok, %Message{}} = Agora.run(parent_config, "Go")

      # Run with pre-cancelled token — should fail at parent level
      CancelToken.cancel(token)

      assert {:error, %Error{type: :cancelled}} =
               Agora.run(parent_config, "Go", cancel_token: token)
    end
  end
end
