defmodule Agora.Tool.BrokerCancelTest do
  use ExUnit.Case, async: true

  alias Agora.{CancelToken, ToolBroker, ToolCall}
  alias Agora.Tool.FunctionTool

  defp make_tool(name, fun) do
    FunctionTool.new!(
      name: name,
      description: "Test tool",
      schema: %{"type" => "object", "properties" => %{}},
      function: fun
    )
  end

  describe "cancel_token option" do
    test "tool tasks are registered in cancel group and killed on hard kill" do
      token = CancelToken.new()
      test_pid = self()

      tool =
        make_tool("slow", fn _args, _ctx ->
          send(test_pid, :tool_started)

          receive do
            :never -> :ok
          end
        end)

      call = ToolCall.new(%{id: "c1", name: "slow", arguments: %{}})

      # Run tool execution in a separate task since it blocks
      broker_task =
        Task.async(fn ->
          ToolBroker.execute([call], [tool], %{}, cancel_token: token)
        end)

      # Wait for the tool to start
      assert_receive :tool_started

      # Kill should terminate the tool task
      CancelToken.kill(token)

      # The broker should return (task was killed)
      {:ok, results} = Task.await(broker_task, 5000)
      assert [result] = results
      # Tool was killed — shows as exit
      assert result.is_error
    end

    test "nil cancel_token works normally (no registration)" do
      tool =
        make_tool("fast", fn _args, _ctx ->
          {:ok, "result"}
        end)

      call = ToolCall.new(%{id: "c1", name: "fast", arguments: %{}})
      assert {:ok, [result]} = ToolBroker.execute([call], [tool], %{}, cancel_token: nil)
      assert result.content == "result"
      refute result.is_error
    end

    test "no cancel_token option at all works normally" do
      tool =
        make_tool("fast", fn _args, _ctx ->
          {:ok, "result"}
        end)

      call = ToolCall.new(%{id: "c1", name: "fast", arguments: %{}})
      assert {:ok, [result]} = ToolBroker.execute([call], [tool], %{})
      assert result.content == "result"
      refute result.is_error
    end
  end
end
