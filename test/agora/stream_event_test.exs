defmodule Agora.StreamEventTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message, StreamEvent, ToolResult}

  describe "text_delta/2" do
    test "creates text delta event" do
      event = StreamEvent.text_delta("hello")
      assert event.type == :text_delta
      assert event.data == %{text: "hello"}
      assert event.metadata == %{}
    end

    test "accepts metadata" do
      event = StreamEvent.text_delta("hi", %{index: 1})
      assert event.metadata == %{index: 1}
    end
  end

  describe "tool_call_start/4" do
    test "creates tool call start event" do
      event = StreamEvent.tool_call_start("id_1", "search", 0)
      assert event.type == :tool_call_start
      assert event.data == %{id: "id_1", name: "search", index: 0}
    end

    test "defaults index to 0" do
      event = StreamEvent.tool_call_start("id_1", "search")
      assert event.data.index == 0
    end
  end

  describe "tool_call_delta/3" do
    test "creates tool call delta event" do
      event = StreamEvent.tool_call_delta("id_1", ~s({"q":))
      assert event.type == :tool_call_delta
      assert event.data == %{id: "id_1", arguments_fragment: ~s({"q":)}
    end
  end

  describe "tool_result/2" do
    test "creates tool result event" do
      result = ToolResult.success("call_1", "search", "found 3")
      event = StreamEvent.tool_result(result)
      assert event.type == :tool_result
      assert event.data == result
    end
  end

  describe "message_complete/2" do
    test "creates message complete event" do
      msg = Message.assistant("Hello!")
      event = StreamEvent.message_complete(msg)
      assert event.type == :message_complete
      assert event.data == msg
    end
  end

  describe "done/1" do
    test "creates done event" do
      event = StreamEvent.done()
      assert event.type == :done
      assert event.data == %{}
    end

    test "accepts metadata" do
      event = StreamEvent.done(%{usage: 42})
      assert event.metadata == %{usage: 42}
    end
  end

  describe "error/2" do
    test "creates error event" do
      err = Error.new(:provider_error, "bad request")
      event = StreamEvent.error(err)
      assert event.type == :error
      assert event.data == err
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      event = StreamEvent.text_delta("hello")
      assert {:ok, json} = Jason.encode(event)
      assert is_binary(json)
    end
  end
end
