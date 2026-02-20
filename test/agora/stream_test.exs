defmodule Agora.StreamTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Stream, StreamEvent}

  describe "Enumerable" do
    test "collects events with Enum.to_list" do
      ref = make_ref()

      pid =
        spawn(fn ->
          receive do
            :start -> :ok
          end
        end)

      stream = Stream.new(ref, pid)

      # Send events from current process (we are the owner)
      send(self(), {Agora.Stream, ref, StreamEvent.text_delta("hello")})
      send(self(), {Agora.Stream, ref, StreamEvent.text_delta(" world")})
      send(self(), {Agora.Stream, ref, StreamEvent.done()})

      events = Enum.to_list(stream)
      assert length(events) == 3
      assert Enum.at(events, 0).type == :text_delta
      assert Enum.at(events, 1).type == :text_delta
      assert Enum.at(events, 2).type == :done
    end

    test ":done terminates the stream" do
      ref = make_ref()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      stream = Stream.new(ref, pid)

      send(self(), {Agora.Stream, ref, StreamEvent.text_delta("hi")})
      send(self(), {Agora.Stream, ref, StreamEvent.done()})

      events = Enum.to_list(stream)
      assert List.last(events).type == :done
    end

    test ":error terminates the stream" do
      ref = make_ref()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      stream = Stream.new(ref, pid)

      error = Error.new(:provider_error, "oops")
      send(self(), {Agora.Stream, ref, StreamEvent.text_delta("hi")})
      send(self(), {Agora.Stream, ref, StreamEvent.error(error)})

      events = Enum.to_list(stream)
      assert length(events) == 2
      assert List.last(events).type == :error
    end

    test "Stream.take works" do
      ref = make_ref()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      stream = Stream.new(ref, pid)

      send(self(), {Agora.Stream, ref, StreamEvent.text_delta("a")})
      send(self(), {Agora.Stream, ref, StreamEvent.text_delta("b")})
      send(self(), {Agora.Stream, ref, StreamEvent.text_delta("c")})
      send(self(), {Agora.Stream, ref, StreamEvent.done()})

      events = stream |> Elixir.Stream.take(2) |> Enum.to_list()
      assert length(events) == 2
    end

    test "Stream.filter works" do
      ref = make_ref()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      stream = Stream.new(ref, pid)

      send(self(), {Agora.Stream, ref, StreamEvent.text_delta("hello")})
      send(self(), {Agora.Stream, ref, StreamEvent.tool_call_start("id", "name")})
      send(self(), {Agora.Stream, ref, StreamEvent.text_delta(" world")})
      send(self(), {Agora.Stream, ref, StreamEvent.done()})

      text_events =
        stream
        |> Elixir.Stream.filter(&(&1.type == :text_delta))
        |> Enum.to_list()

      assert length(text_events) == 2
      assert Enum.all?(text_events, &(&1.type == :text_delta))
    end

    test "process crash delivers error event" do
      ref = make_ref()
      pid = spawn(fn -> :ok end)
      # Process is already dead
      Process.sleep(10)
      stream = Stream.new(ref, pid)

      events = Enum.to_list(stream)
      assert length(events) == 1
      assert hd(events).type == :error
      assert hd(events).data.type == :streaming_error
    end

    test "raises ArgumentError when enumerated from wrong process" do
      ref = make_ref()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      # Create with a different owner
      other_pid = spawn(fn -> Process.sleep(:infinity) end)
      stream = Stream.new(ref, pid, other_pid)

      assert_raise ArgumentError, ~r/owner process/, fn ->
        Enum.to_list(stream)
      end
    end
  end
end
