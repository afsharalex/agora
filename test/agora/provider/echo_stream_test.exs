defmodule Agora.Provider.EchoStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message, StreamEvent}
  alias Agora.Provider.Echo

  defp echo_config(opts \\ []) do
    AgentConfig.new!(Keyword.merge([provider: :echo, model: "echo"], opts))
  end

  describe "stream_chat/2 with :echo mode" do
    test "streams character-by-character then message_complete and done" do
      config = echo_config()
      messages = [Message.user("Hi")]

      {:ok, %{pid: pid, ref: ref}} = Echo.stream_chat(messages, config)
      assert is_pid(pid)
      assert is_reference(ref)

      # Collect all events
      events = collect_events(ref)

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0

      full_text = Enum.map_join(text_deltas, & &1.data.text)
      assert full_text == "Echo: Hi"

      assert Enum.any?(events, &(&1.type == :message_complete))
      assert List.last(events).type == :done
    end
  end

  describe "stream_chat/2 with :static mode" do
    test "streams word-by-word" do
      config = echo_config(provider_opts: [echo_mode: :static, echo_response: "Hello world"])
      messages = [Message.user("test")]

      {:ok, %{ref: ref}} = Echo.stream_chat(messages, config)
      events = collect_events(ref)

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete.data.content == "Hello world"
    end
  end

  describe "stream_chat/2 with :stream mode" do
    test "replays explicit events list" do
      custom_events = [
        StreamEvent.text_delta("Hello"),
        StreamEvent.text_delta(" world"),
        StreamEvent.message_complete(Message.assistant("Hello world")),
        StreamEvent.done()
      ]

      config =
        echo_config(provider_opts: [echo_mode: :stream, echo_stream_events: custom_events])

      {:ok, %{ref: ref}} = Echo.stream_chat([Message.user("x")], config)
      events = collect_events(ref)

      assert length(events) == 4
      assert Enum.at(events, 0).type == :text_delta
      assert Enum.at(events, 0).data.text == "Hello"
      assert Enum.at(events, 3).type == :done
    end

    test "uses stream function when provided" do
      fun = fn caller, ref ->
        send(caller, {Agora.Stream, ref, StreamEvent.text_delta("custom")})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})
      end

      config =
        echo_config(provider_opts: [echo_mode: :stream, echo_stream_function: fun])

      {:ok, %{ref: ref}} = Echo.stream_chat([Message.user("x")], config)
      events = collect_events(ref)

      assert length(events) == 2
      assert hd(events).data.text == "custom"
    end

    test "supports delay between events" do
      events = [
        StreamEvent.text_delta("a"),
        StreamEvent.text_delta("b"),
        StreamEvent.done()
      ]

      config =
        echo_config(
          provider_opts: [echo_mode: :stream, echo_stream_events: events, echo_stream_delay: 10]
        )

      start = System.monotonic_time(:millisecond)
      {:ok, %{ref: ref}} = Echo.stream_chat([Message.user("x")], config)
      _events = collect_events(ref)
      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed >= 20
    end
  end

  describe "stream_chat/2 with :tool_call mode" do
    test "streams tool call events" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :tool_call,
            echo_tool_calls: [%{name: "search", arguments: %{"q" => "test"}}]
          ]
        )

      {:ok, %{ref: ref}} = Echo.stream_chat([Message.user("x")], config)
      events = collect_events(ref)

      starts = Enum.filter(events, &(&1.type == :tool_call_start))
      assert length(starts) == 1
      assert hd(starts).data.name == "search"

      deltas = Enum.filter(events, &(&1.type == :tool_call_delta))
      assert length(deltas) == 1

      assert Enum.any?(events, &(&1.type == :message_complete))
      assert List.last(events).type == :done
    end
  end

  describe "stream_chat/2 with :error mode" do
    test "sends error and done events" do
      config =
        echo_config(
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "test error"
          ]
        )

      {:ok, %{ref: ref}} = Echo.stream_chat([Message.user("x")], config)
      events = collect_events(ref)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event.data.message == "test error"
      assert List.last(events).type == :done
    end
  end

  # --- Helpers ---

  defp collect_events(ref, timeout \\ 5000) do
    collect_events_loop(ref, [], timeout)
  end

  defp collect_events_loop(ref, acc, timeout) do
    receive do
      {Agora.Stream, ^ref, %StreamEvent{type: :done} = event} ->
        Enum.reverse([event | acc])

      {Agora.Stream, ^ref, %StreamEvent{} = event} ->
        collect_events_loop(ref, [event | acc], timeout)
    after
      timeout ->
        Enum.reverse(acc)
    end
  end
end
