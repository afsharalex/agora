defmodule Agora.Provider.AnthropicStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message, StreamEvent}
  alias Agora.Provider.Anthropic

  setup _context do
    test_pid = self()

    Req.Test.stub(Agora.Provider.AnthropicStreamTest, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(test_pid, {:request_body, decoded})

      response = build_sse_response(decoded)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, response)
    end)

    {:ok, test_pid: test_pid}
  end

  defp stream_config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [
          provider: :anthropic,
          model: "claude-test",
          provider_opts: [
            api_key: "test-key",
            req_options: [plug: {Req.Test, Agora.Provider.AnthropicStreamTest}]
          ]
        ],
        opts
      )
    )
  end

  describe "stream_chat/2" do
    test "sends stream: true in request body" do
      config = stream_config()
      messages = [Message.user("Hello")]

      {:ok, %{ref: ref, pid: pid}} = Anthropic.stream_chat(messages, config)
      Req.Test.allow(Agora.Provider.AnthropicStreamTest, self(), pid)
      _events = collect_events(ref)

      assert_receive {:request_body, body}
      assert body["stream"] == true
    end

    test "streams text deltas" do
      config = stream_config()
      messages = [Message.user("Hello")]

      {:ok, %{ref: ref}} = Anthropic.stream_chat(messages, config)
      events = collect_events(ref)

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0
      assert hd(text_deltas).data.text == "Hello"

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert complete.data.content == "Hello"
    end

    test "handles tool use streaming" do
      Req.Test.stub(Agora.Provider.AnthropicStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","model":"claude-test","usage":{"input_tokens":10}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"search"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":\\"test\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}

        event: message_stop
        data: {"type":"message_stop"}

        """

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Anthropic.stream_chat([Message.user("search test")], config)
      events = collect_events(ref)

      starts = Enum.filter(events, &(&1.type == :tool_call_start))
      assert length(starts) == 1
      assert hd(starts).data.name == "search"

      deltas = Enum.filter(events, &(&1.type == :tool_call_delta))
      assert length(deltas) == 1

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert length(complete.data.tool_calls) == 1
      assert hd(complete.data.tool_calls).name == "search"
    end

    test "handles interleaved multi-tool deltas correctly" do
      Req.Test.stub(Agora.Provider.AnthropicStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","model":"claude-test","usage":{"input_tokens":10}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"search"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_2","name":"calc"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"x\\":"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"test\\"}"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"42\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":10}}

        event: message_stop
        data: {"type":"message_stop"}

        """

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Anthropic.stream_chat([Message.user("multi tool")], config)
      events = collect_events(ref)

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert length(complete.data.tool_calls) == 2

      [tc1, tc2] = complete.data.tool_calls
      assert tc1.name == "search"
      assert tc1.arguments == %{"q" => "test"}
      assert tc2.name == "calc"
      assert tc2.arguments == %{"x" => "42"}
    end

    test "handles auth error before streaming" do
      config =
        AgentConfig.new!(
          provider: :anthropic,
          model: "claude-test",
          provider_opts: [
            api_key: nil,
            req_options: [plug: {Req.Test, Agora.Provider.AnthropicStreamTest}]
          ]
        )

      result = Anthropic.stream_chat([Message.user("test")], config)
      assert {:error, %{type: :auth_error}} = result
    end

    test "handles HTTP error response" do
      Req.Test.stub(Agora.Provider.AnthropicStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        body = Jason.encode!(%{"error" => %{"message" => "rate limited"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, body)
      end)

      config = stream_config()
      {:ok, %{pid: pid, ref: ref}} = Anthropic.stream_chat([Message.user("test")], config)
      Req.Test.allow(Agora.Provider.AnthropicStreamTest, self(), pid)
      events = collect_events(ref)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
      assert error_event.data.type == :rate_limit
    end
  end

  # --- Helpers ---

  defp build_sse_response(_request) do
    """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","model":"claude-test","usage":{"input_tokens":10}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

    event: message_stop
    data: {"type":"message_stop"}

    """
  end

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
