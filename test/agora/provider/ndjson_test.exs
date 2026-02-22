defmodule Agora.Provider.NDJSONTest do
  use ExUnit.Case, async: true

  alias Agora.Provider.NDJSON

  describe "parse/2" do
    test "parses a single complete JSON line" do
      state = NDJSON.new()
      {events, _state} = NDJSON.parse(state, ~s({"message":"hello"}\n))
      assert events == [%{"message" => "hello"}]
    end

    test "parses multiple JSON lines in one chunk" do
      state = NDJSON.new()

      data = ~s({"a":1}\n{"b":2}\n{"c":3}\n)
      {events, _state} = NDJSON.parse(state, data)

      assert events == [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
    end

    test "buffers partial lines across multiple parse calls" do
      state = NDJSON.new()

      {events1, state} = NDJSON.parse(state, ~s({"mess))
      assert events1 == []

      {events2, _state} = NDJSON.parse(state, ~s(age":"hello"}\n))
      assert events2 == [%{"message" => "hello"}]
    end

    test "ignores empty lines" do
      state = NDJSON.new()
      {events, _state} = NDJSON.parse(state, ~s({"a":1}\n\n{"b":2}\n))
      assert events == [%{"a" => 1}, %{"b" => 2}]
    end

    test "silently drops malformed JSON lines" do
      state = NDJSON.new()
      {events, _state} = NDJSON.parse(state, ~s({"a":1}\nnot json\n{"b":2}\n))
      assert events == [%{"a" => 1}, %{"b" => 2}]
    end

    test "handles \\r\\n line endings" do
      state = NDJSON.new()
      {events, _state} = NDJSON.parse(state, ~s({"a":1}\r\n{"b":2}\r\n))
      assert events == [%{"a" => 1}, %{"b" => 2}]
    end

    test "handles bare \\r line endings" do
      state = NDJSON.new()
      {events, _state} = NDJSON.parse(state, ~s({"a":1}\r{"b":2}\r))
      assert events == [%{"a" => 1}, %{"b" => 2}]
    end
  end

  describe "flush/1" do
    test "returns empty for empty buffer" do
      state = NDJSON.new()
      assert {[], _state} = NDJSON.flush(state)
    end

    test "parses buffered trailing data" do
      state = NDJSON.new()
      {[], state} = NDJSON.parse(state, ~s({"done":true}))
      {events, _state} = NDJSON.flush(state)
      assert events == [%{"done" => true}]
    end

    test "drops malformed trailing data" do
      state = %{buffer: "not valid json"}
      {events, _state} = NDJSON.flush(state)
      assert events == []
    end
  end
end
