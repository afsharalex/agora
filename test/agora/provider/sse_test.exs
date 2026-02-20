defmodule Agora.Provider.SSETest do
  use ExUnit.Case, async: true

  alias Agora.Provider.SSE

  describe "new/0" do
    test "creates empty parser state" do
      assert SSE.new() == %{buffer: ""}
    end
  end

  describe "parse/2" do
    test "parses a single complete event" do
      state = SSE.new()
      {events, state} = SSE.parse(state, "data: hello\n\n")
      assert [%{data: "hello", event: nil, id: nil}] = events
      assert state.buffer == ""
    end

    test "parses multiple events in one chunk" do
      state = SSE.new()
      input = "data: first\n\ndata: second\n\n"
      {events, _state} = SSE.parse(state, input)
      assert length(events) == 2
      assert Enum.at(events, 0).data == "first"
      assert Enum.at(events, 1).data == "second"
    end

    test "buffers incomplete events" do
      state = SSE.new()
      {events, state} = SSE.parse(state, "data: partial")
      assert events == []
      assert state.buffer == "data: partial"
    end

    test "handles partial buffering across calls" do
      state = SSE.new()
      {[], state} = SSE.parse(state, "data: hel")
      {events, _state} = SSE.parse(state, "lo\n\n")
      assert [%{data: "hello"}] = events
    end

    test "parses event type field" do
      state = SSE.new()
      {events, _} = SSE.parse(state, "event: message_start\ndata: {}\n\n")
      assert [%{event: "message_start", data: "{}"}] = events
    end

    test "parses id field" do
      state = SSE.new()
      {events, _} = SSE.parse(state, "id: 42\ndata: test\n\n")
      assert [%{id: "42", data: "test"}] = events
    end

    test "joins multiple data lines with newline" do
      state = SSE.new()
      {events, _} = SSE.parse(state, "data: line1\ndata: line2\n\n")
      assert [%{data: "line1\nline2"}] = events
    end

    test "ignores comment lines" do
      state = SSE.new()
      {events, _} = SSE.parse(state, ": this is a comment\ndata: hello\n\n")
      assert [%{data: "hello"}] = events
    end

    test "ignores empty blocks" do
      state = SSE.new()
      {events, _} = SSE.parse(state, "\n\ndata: hello\n\n")
      assert [%{data: "hello"}] = events
    end

    test "handles \\r\\n line endings" do
      state = SSE.new()
      {events, _} = SSE.parse(state, "data: hello\r\n\r\n")
      assert [%{data: "hello"}] = events
    end

    test "handles lone \\r line endings" do
      state = SSE.new()
      {events, _} = SSE.parse(state, "data: hello\r\r")
      assert [%{data: "hello"}] = events
    end

    test "handles Anthropic SSE format" do
      state = SSE.new()

      input =
        ~s(event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1"}}\n\n) <>
          ~s(event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n)

      {events, _} = SSE.parse(state, input)
      assert length(events) == 2
      assert Enum.at(events, 0).event == "message_start"
      assert Enum.at(events, 1).event == "content_block_delta"
    end

    test "handles OpenAI SSE format" do
      state = SSE.new()

      input =
        ~s(data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n) <>
          ~s(data: [DONE]\n\n)

      {events, _} = SSE.parse(state, input)
      assert length(events) == 2
      assert Enum.at(events, 1).data == "[DONE]"
    end
  end

  describe "flush/1" do
    test "returns empty for empty buffer" do
      state = SSE.new()
      {events, state} = SSE.flush(state)
      assert events == []
      assert state.buffer == ""
    end

    test "parses remaining buffer content" do
      state = %{buffer: "data: final"}
      {events, state} = SSE.flush(state)
      assert [%{data: "final"}] = events
      assert state.buffer == ""
    end

    test "returns empty for buffer with only whitespace" do
      state = %{buffer: "  "}
      {events, _state} = SSE.flush(state)
      assert events == []
    end
  end
end
