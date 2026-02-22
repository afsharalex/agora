defmodule Agora.Provider.OllamaStreamTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message, StreamEvent}
  alias Agora.Provider.Ollama

  setup do
    Req.Test.stub(Agora.Provider.OllamaStreamTest, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      response = build_text_ndjson_response()

      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_resp(200, response)
    end)

    :ok
  end

  defp stream_config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [
          provider: :ollama,
          model: "llama3.2",
          provider_opts: [
            api_key: "test-key",
            req_options: [plug: {Req.Test, Agora.Provider.OllamaStreamTest}]
          ]
        ],
        opts
      )
    )
  end

  describe "stream_chat/2" do
    test "streams NDJSON text deltas" do
      config = stream_config()
      messages = [Message.user("Hello")]

      {:ok, %{ref: ref}} = Ollama.stream_chat(messages, config)
      events = collect_events(ref)

      text_deltas = Enum.filter(events, &(&1.type == :text_delta))
      assert length(text_deltas) > 0
      assert hd(text_deltas).data.text == "Hello"

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert complete.data.content == "Hello world"
    end

    test "handles done marker" do
      config = stream_config()
      {:ok, %{ref: ref}} = Ollama.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      assert List.last(events).type == :done
    end

    test "sends stream: true in request body" do
      Req.Test.stub(Agora.Provider.OllamaStreamTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["stream"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(200, build_text_ndjson_response())
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Ollama.stream_chat([Message.user("test")], config)
      _events = collect_events(ref)
    end

    test "handles tool calls in streaming" do
      Req.Test.stub(Agora.Provider.OllamaStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        chunk1 =
          Jason.encode!(%{
            "message" => %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [
                %{"function" => %{"name" => "search", "arguments" => %{"q" => "test"}}}
              ]
            },
            "done" => false
          })

        chunk2 = Jason.encode!(%{"done" => true, "done_reason" => "stop"})

        response = chunk1 <> "\n" <> chunk2 <> "\n"

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(200, response)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Ollama.stream_chat([Message.user("search")], config)
      events = collect_events(ref)

      starts = Enum.filter(events, &(&1.type == :tool_call_start))
      assert length(starts) == 1
      assert hd(starts).data.name == "search"

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete != nil
      assert length(complete.data.tool_calls) == 1
      assert hd(complete.data.tool_calls).arguments == %{"q" => "test"}
    end

    test "tool calls across multiple chunks get unique indices" do
      Req.Test.stub(Agora.Provider.OllamaStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        chunk1 =
          Jason.encode!(%{
            "message" => %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [
                %{"function" => %{"name" => "get_weather", "arguments" => %{"city" => "Tokyo"}}}
              ]
            },
            "done" => false
          })

        chunk2 =
          Jason.encode!(%{
            "message" => %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [
                %{"function" => %{"name" => "get_weather", "arguments" => %{"city" => "London"}}}
              ]
            },
            "done" => false
          })

        chunk3 = Jason.encode!(%{"done" => true, "done_reason" => "stop"})

        response = chunk1 <> "\n" <> chunk2 <> "\n" <> chunk3 <> "\n"

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(200, response)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Ollama.stream_chat([Message.user("weather")], config)
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

    test "captures metadata from done event" do
      Req.Test.stub(Agora.Provider.OllamaStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        chunk1 =
          Jason.encode!(%{
            "message" => %{"role" => "assistant", "content" => "Hi"},
            "done" => false
          })

        chunk2 =
          Jason.encode!(%{
            "done" => true,
            "done_reason" => "stop",
            "model" => "llama3.2",
            "total_duration" => 174_560_334,
            "eval_count" => 18,
            "eval_duration" => 64_560_334,
            "prompt_eval_count" => 52
          })

        response = chunk1 <> "\n" <> chunk2 <> "\n"

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(200, response)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Ollama.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      complete = Enum.find(events, &(&1.type == :message_complete))
      assert complete.data.metadata[:stop_reason] == "stop"
      assert complete.data.metadata[:model] == "llama3.2"
      assert complete.data.metadata[:total_duration] == 174_560_334
      assert complete.data.metadata[:eval_count] == 18
      assert complete.data.metadata[:prompt_eval_count] == 52
    end

    test "handles HTTP error response" do
      Req.Test.stub(Agora.Provider.OllamaStreamTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        body = Jason.encode!(%{"error" => "model not found"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, body)
      end)

      config = stream_config()
      {:ok, %{ref: ref}} = Ollama.stream_chat([Message.user("test")], config)
      events = collect_events(ref)

      error_event = Enum.find(events, &(&1.type == :error))
      assert error_event != nil
      assert error_event.data.type == :validation_error
    end
  end

  # --- Helpers ---

  defp build_text_ndjson_response do
    chunk1 =
      Jason.encode!(%{
        "message" => %{"role" => "assistant", "content" => "Hello"},
        "done" => false
      })

    chunk2 =
      Jason.encode!(%{
        "message" => %{"role" => "assistant", "content" => " world"},
        "done" => false
      })

    chunk3 =
      Jason.encode!(%{
        "done" => true,
        "done_reason" => "stop"
      })

    chunk1 <> "\n" <> chunk2 <> "\n" <> chunk3 <> "\n"
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
