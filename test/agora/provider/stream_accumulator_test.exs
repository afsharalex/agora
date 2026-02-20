defmodule Agora.Provider.StreamAccumulatorTest do
  use ExUnit.Case, async: true

  alias Agora.{Message, StreamEvent}
  alias Agora.Provider.StreamAccumulator

  describe "new/0" do
    test "creates empty accumulator" do
      acc = StreamAccumulator.new()
      assert acc.content == ""
      assert acc.tool_calls == %{}
      assert acc.metadata == %{}
    end
  end

  describe "apply/2" do
    test "accumulates text deltas" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.text_delta("Hello"))
        |> StreamAccumulator.apply(StreamEvent.text_delta(" world"))

      assert acc.content == "Hello world"
    end

    test "accumulates tool call start" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_1", "search", 0))

      assert Map.has_key?(acc.tool_calls, 0)
      assert acc.tool_calls[0].id == "id_1"
      assert acc.tool_calls[0].name == "search"
      assert acc.tool_calls[0].arguments == ""
    end

    test "accumulates tool call deltas" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_1", "search", 0))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_1", ~s({"q":)))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_1", ~s( "elixir"})))

      assert acc.tool_calls[0].arguments == ~s({"q": "elixir"})
    end

    test "handles multiple tool calls" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_1", "search", 0))
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_2", "calc", 1))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_1", ~s({"q":"a"})))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_2", ~s({"x":1})))

      assert acc.tool_calls[0].name == "search"
      assert acc.tool_calls[1].name == "calc"
    end

    test "ignores other event types" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.done())
        |> StreamAccumulator.apply(StreamEvent.error(Agora.Error.new(:provider_error, "x")))

      assert acc.content == ""
      assert acc.tool_calls == %{}
    end
  end

  describe "to_message/1" do
    test "builds message with text content" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.text_delta("Hello"))
        |> StreamAccumulator.apply(StreamEvent.text_delta(" world"))

      msg = StreamAccumulator.to_message(acc)
      assert %Message{role: :assistant, content: "Hello world"} = msg
      assert msg.tool_calls == []
    end

    test "empty content becomes nil" do
      acc = StreamAccumulator.new()
      msg = StreamAccumulator.to_message(acc)
      assert msg.content == nil
    end

    test "builds message with tool calls" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_1", "search", 0))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_1", ~s({"q":"elixir"})))

      msg = StreamAccumulator.to_message(acc)
      assert msg.content == nil
      assert length(msg.tool_calls) == 1
      assert hd(msg.tool_calls).id == "id_1"
      assert hd(msg.tool_calls).name == "search"
      assert hd(msg.tool_calls).arguments == %{"q" => "elixir"}
    end

    test "JSON decodes tool arguments" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_1", "calc", 0))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_1", ~s({"a":1,"b":2})))

      msg = StreamAccumulator.to_message(acc)
      assert hd(msg.tool_calls).arguments == %{"a" => 1, "b" => 2}
    end

    test "malformed JSON falls back to _raw" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_1", "calc", 0))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_1", "not json"))

      msg = StreamAccumulator.to_message(acc)
      assert hd(msg.tool_calls).arguments == %{"_raw" => "not json"}
    end

    test "attaches accumulated metadata to message" do
      acc = %{
        StreamAccumulator.new()
        | metadata: %{stop_reason: "end_turn", usage: %{"output_tokens" => 5}}
      }

      acc =
        acc
        |> StreamAccumulator.apply(StreamEvent.text_delta("Hello"))

      msg = StreamAccumulator.to_message(acc)
      assert msg.content == "Hello"
      assert msg.metadata.stop_reason == "end_turn"
      assert msg.metadata.usage == %{"output_tokens" => 5}
    end

    test "no metadata leaves message metadata as default" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.text_delta("Hello"))

      msg = StreamAccumulator.to_message(acc)
      assert msg.metadata == %{}
    end

    test "preserves tool call order by index" do
      acc =
        StreamAccumulator.new()
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_2", "second", 1))
        |> StreamAccumulator.apply(StreamEvent.tool_call_start("id_1", "first", 0))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_1", ~s({})))
        |> StreamAccumulator.apply(StreamEvent.tool_call_delta("id_2", ~s({})))

      msg = StreamAccumulator.to_message(acc)
      assert Enum.at(msg.tool_calls, 0).name == "first"
      assert Enum.at(msg.tool_calls, 1).name == "second"
    end
  end
end
