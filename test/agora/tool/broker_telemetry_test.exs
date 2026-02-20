defmodule Agora.ToolBrokerTelemetryTest do
  use ExUnit.Case, async: true

  alias Agora.{ToolCall, ToolBroker}
  alias Agora.Tool.FunctionTool

  defp attach_handler(events) do
    ref = make_ref()
    test_pid = self()
    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ref
  end

  defp tool_events do
    [
      [:agora, :tool, :call, :start],
      [:agora, :tool, :call, :stop],
      [:agora, :tool, :call, :exception]
    ]
  end

  defp make_tool(name, fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    FunctionTool.new!(
      name: name,
      description: "test tool",
      schema: %{},
      function: fun,
      timeout: timeout
    )
  end

  defp make_call(name, id \\ "call-1") do
    %ToolCall{id: id, name: name, arguments: %{}}
  end

  describe "tool telemetry" do
    test "successful tool emits start and stop with status :ok" do
      ref = attach_handler(tool_events())
      tool = make_tool("ok_tool", fn _args, _ctx -> {:ok, "result"} end)
      call = make_call("ok_tool")

      {:ok, [_result]} = ToolBroker.execute([call], [tool])

      assert_receive {^ref, [:agora, :tool, :call, :start], %{system_time: _},
                      %{tool_name: "ok_tool", tool_call_id: "call-1"}}

      assert_receive {^ref, [:agora, :tool, :call, :stop], %{duration: duration},
                      %{tool_name: "ok_tool", tool_call_id: "call-1", status: :ok}}

      assert is_integer(duration) and duration >= 0
    end

    test "tool error return emits stop with status :error" do
      ref = attach_handler(tool_events())
      tool = make_tool("err_tool", fn _args, _ctx -> {:error, "bad input"} end)
      call = make_call("err_tool")

      {:ok, [result]} = ToolBroker.execute([call], [tool])
      assert result.is_error

      assert_receive {^ref, [:agora, :tool, :call, :start], _, _}

      assert_receive {^ref, [:agora, :tool, :call, :stop], _,
                      %{tool_name: "err_tool", status: :error}}
    end

    test "tool raise emits exception AND stop with status :error" do
      ref = attach_handler(tool_events())

      tool =
        make_tool("raise_tool", fn _args, _ctx ->
          raise "tool boom"
        end)

      call = make_call("raise_tool")

      {:ok, [result]} = ToolBroker.execute([call], [tool])
      assert result.is_error

      assert_receive {^ref, [:agora, :tool, :call, :start], _, %{tool_name: "raise_tool"}}

      assert_receive {^ref, [:agora, :tool, :call, :exception], %{duration: 0},
                      %{
                        tool_name: "raise_tool",
                        tool_call_id: "call-1",
                        kind: :error,
                        reason: "tool boom"
                      }}

      assert_receive {^ref, [:agora, :tool, :call, :stop], _,
                      %{tool_name: "raise_tool", status: :error}}
    end

    test "tool timeout emits stop with status :timeout" do
      ref = attach_handler(tool_events())

      tool =
        make_tool(
          "slow_tool",
          fn _args, _ctx ->
            Process.sleep(5_000)
            {:ok, "never"}
          end,
          timeout: 50
        )

      call = make_call("slow_tool")

      {:ok, [result]} = ToolBroker.execute([call], [tool])
      assert result.is_error
      assert result.content =~ "timed out"

      assert_receive {^ref, [:agora, :tool, :call, :start], _, %{tool_name: "slow_tool"}}

      assert_receive {^ref, [:agora, :tool, :call, :stop], _,
                      %{tool_name: "slow_tool", status: :timeout}},
                     5_000
    end

    test "tool exit emits exception with kind :exit and stop with status :error" do
      ref = attach_handler(tool_events())

      tool =
        make_tool("exit_tool", fn _args, _ctx ->
          exit(:tool_died)
        end)

      call = make_call("exit_tool")

      {:ok, [result]} = ToolBroker.execute([call], [tool])
      assert result.is_error

      assert_receive {^ref, [:agora, :tool, :call, :start], _, %{tool_name: "exit_tool"}}

      assert_receive {^ref, [:agora, :tool, :call, :exception], _,
                      %{tool_name: "exit_tool", kind: :exit}}

      assert_receive {^ref, [:agora, :tool, :call, :stop], _,
                      %{tool_name: "exit_tool", status: :error}}
    end

    test "metadata contains tool_name and tool_call_id" do
      ref = attach_handler(tool_events())
      tool = make_tool("meta_tool", fn _args, _ctx -> {:ok, "ok"} end)
      call = make_call("meta_tool", "unique-id-42")

      {:ok, _} = ToolBroker.execute([call], [tool])

      assert_receive {^ref, [:agora, :tool, :call, :start], _,
                      %{tool_name: "meta_tool", tool_call_id: "unique-id-42"}}

      assert_receive {^ref, [:agora, :tool, :call, :stop], _,
                      %{tool_name: "meta_tool", tool_call_id: "unique-id-42"}}
    end

    test "multiple tools each emit their own start/stop" do
      ref = attach_handler(tool_events())

      tool_a = make_tool("tool_a", fn _args, _ctx -> {:ok, "a"} end)
      tool_b = make_tool("tool_b", fn _args, _ctx -> {:ok, "b"} end)

      call_a = make_call("tool_a", "id-a")
      call_b = make_call("tool_b", "id-b")

      {:ok, _} = ToolBroker.execute([call_a, call_b], [tool_a, tool_b])

      assert_receive {^ref, [:agora, :tool, :call, :start], _, %{tool_name: "tool_a"}}
      assert_receive {^ref, [:agora, :tool, :call, :start], _, %{tool_name: "tool_b"}}
      assert_receive {^ref, [:agora, :tool, :call, :stop], _, %{tool_name: "tool_a", status: :ok}}
      assert_receive {^ref, [:agora, :tool, :call, :stop], _, %{tool_name: "tool_b", status: :ok}}
    end
  end
end
