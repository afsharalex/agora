defmodule Agora.Provider.OpenAIStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message, StreamEvent}
  alias Agora.Provider.OpenAI

  setup do
    Req.Test.stub(Agora.Provider.OpenAIStreamTest, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      response = build_text_sse_response()

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, response)
    end)

    :ok
  end

  defp stream_config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [
          provider: :openai,
          model: "gpt-test",
          provider_opts: [
            api_key: "test-key",
            req_options: [plug: {Req.Test, Agora.Provider.OpenAIStreamTest}]
          ]
        ],
        opts
      )
    )
  end

  describe "stream_chat/2" do
    test "streams text deltas" do
      config = stream_config()
      messages = [Message.user("Hello")]

      {:ok, %{ref: ref}} = OpenAI.stream_chat(messages, config)
      events = collect_events(ref)

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0
      assert hd(text_deltas).data.text == "Hello"

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert complete.data.content == "Hello world"
    end

    test "handles [DONE] marker" do
      config = stream_config()
      {:ok, %{ref: ref}} = OpenAI.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      assert List.last(events).type == :done
    end

    test "handles tool call streaming" do
      Req.Test.stub(Agora.Provider.OpenAIStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        sse = """
        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"q\\""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"test\\"}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = OpenAI.stream_chat([Message.user("search")], config)
      events = collect_events(ref)

      starts = Enum.filter(events, &(&1.type == :tool_call_start))
      assert length(starts) == 1
      assert hd(starts).data.name == "search"

      deltas = Enum.filter(events, &(&1.type == :tool_call_delta))
      assert length(deltas) == 2

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert length(complete.data.tool_calls) == 1
      assert hd(complete.data.tool_calls).arguments == %{"q" => "test"}
    end

    test "handles auth error via 401 response" do
      Req.Test.stub(Agora.Provider.OpenAIStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        body = Jason.encode!(%{"error" => %{"message" => "Unauthorized"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, body)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = OpenAI.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
      assert error_event.data.type == :auth_error
    end

    test "handles HTTP error response" do
      Req.Test.stub(Agora.Provider.OpenAIStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        body = Jason.encode!(%{"error" => %{"message" => "rate limited"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, body)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = OpenAI.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
      assert error_event.data.type == :rate_limit
    end
  end

  # --- Helpers ---

  defp build_text_sse_response do
    """
    data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"}}]}

    data: {"choices":[{"index":0,"delta":{"content":" world"}}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

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
