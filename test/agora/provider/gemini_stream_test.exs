defmodule Agora.Provider.GeminiStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message, StreamEvent}
  alias Agora.Provider.Gemini

  setup do
    Req.Test.stub(Agora.Provider.GeminiStreamTest, fn conn ->
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
          provider: :gemini,
          model: "gemini-2.0-flash",
          provider_opts: [
            api_key: "test-key",
            req_options: [plug: {Req.Test, Agora.Provider.GeminiStreamTest}]
          ]
        ],
        opts
      )
    )
  end

  describe "stream_chat/2" do
    test "streams text deltas via SSE" do
      config = stream_config()
      messages = [Message.user("Hello")]

      {:ok, %{ref: ref}} = Gemini.stream_chat(messages, config)
      events = collect_events(ref)

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0
      assert hd(text_deltas).data.text == "Hello"

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert complete.data.content == "Hello world"
    end

    test "sends alt=sse query param in request URL" do
      Req.Test.stub(Agora.Provider.GeminiStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        assert conn.query_string =~ "alt=sse"
        assert conn.query_string =~ "key=test-key"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, build_text_sse_response())
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Gemini.stream_chat([Message.user("test")], config)
      _events = collect_events(ref)
    end

    test "handles tool calls in streaming" do
      Req.Test.stub(Agora.Provider.GeminiStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        candidate = %{
          "candidates" => [
            %{
              "content" => %{
                "role" => "model",
                "parts" => [
                  %{"functionCall" => %{"name" => "search", "args" => %{"q" => "test"}}}
                ]
              },
              "finishReason" => "STOP"
            }
          ]
        }

        sse = "data: #{Jason.encode!(candidate)}\n\n"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Gemini.stream_chat([Message.user("search")], config)
      events = collect_events(ref)

      starts = Enum.filter(events, &(&1.type == :tool_call_start))
      assert length(starts) == 1
      assert hd(starts).data.name == "search"

      deltas = Enum.filter(events, &(&1.type == :tool_call_delta))
      assert length(deltas) == 1

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert length(complete.data.tool_calls) == 1
      assert hd(complete.data.tool_calls).arguments == %{"q" => "test"}
    end

    test "tool calls across multiple chunks get unique indices" do
      Req.Test.stub(Agora.Provider.GeminiStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        chunk1 = %{
          "candidates" => [
            %{
              "content" => %{
                "role" => "model",
                "parts" => [
                  %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Tokyo"}}}
                ]
              }
            }
          ]
        }

        chunk2 = %{
          "candidates" => [
            %{
              "content" => %{
                "role" => "model",
                "parts" => [
                  %{
                    "functionCall" => %{"name" => "get_weather", "args" => %{"city" => "London"}}
                  }
                ]
              },
              "finishReason" => "STOP"
            }
          ]
        }

        sse = "data: #{Jason.encode!(chunk1)}\n\ndata: #{Jason.encode!(chunk2)}\n\n"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Gemini.stream_chat([Message.user("weather")], config)
      events = collect_events(ref)

      starts = Enum.filter(events, &(&1.type == :tool_call_start))
      assert length(starts) == 2

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert length(complete.data.tool_calls) == 2

      [tc1, tc2] = complete.data.tool_calls
      assert tc1.name == "get_weather"
      assert tc1.arguments == %{"city" => "Tokyo"}
      assert tc2.name == "get_weather"
      assert tc2.arguments == %{"city" => "London"}
      assert tc1.id != tc2.id
    end

    test "captures metadata from streaming events" do
      Req.Test.stub(Agora.Provider.GeminiStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        chunk = %{
          "candidates" => [
            %{
              "content" => %{"role" => "model", "parts" => [%{"text" => "Hello"}]},
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 5,
            "totalTokenCount" => 15
          },
          "modelVersion" => "gemini-2.0-flash"
        }

        sse = "data: #{Jason.encode!(chunk)}\n\n"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Gemini.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete.data.metadata[:stop_reason] == "STOP"
      assert complete.data.metadata[:model] == "gemini-2.0-flash"

      assert complete.data.metadata[:usage] == %{
               prompt_tokens: 10,
               completion_tokens: 5,
               total_tokens: 15
             }
    end

    test "handles auth error before streaming" do
      Req.Test.stub(Agora.Provider.GeminiStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        body = Jason.encode!(%{"error" => %{"message" => "Unauthorized"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, body)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Gemini.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
      assert error_event.data.type == :auth_error
    end

    test "handles HTTP error during streaming" do
      Req.Test.stub(Agora.Provider.GeminiStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        body = Jason.encode!(%{"error" => %{"message" => "rate limited"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, body)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Gemini.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
      assert error_event.data.type == :rate_limit
    end
  end

  # --- Helpers ---

  defp build_text_sse_response do
    chunk1 = %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => "Hello"}]}
        }
      ]
    }

    chunk2 = %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => " world"}]},
          "finishReason" => "STOP"
        }
      ]
    }

    """
    data: #{Jason.encode!(chunk1)}

    data: #{Jason.encode!(chunk2)}

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
