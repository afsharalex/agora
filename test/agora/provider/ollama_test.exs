defmodule Agora.Provider.OllamaTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message, ToolCall, ToolResult}
  alias Agora.Provider.Ollama

  defp config(opts \\ []) do
    defaults = [
      provider: :ollama,
      model: "llama3.2",
      provider_opts: [
        api_key: "test-key",
        req_options: [plug: {Req.Test, __MODULE__}, retry: false]
      ]
    ]

    AgentConfig.new!(deep_merge_opts(defaults, opts))
  end

  defp deep_merge_opts(defaults, overrides) do
    Keyword.merge(defaults, overrides, fn
      :provider_opts, default, override ->
        Keyword.merge(default, override)

      _key, _default, override ->
        override
    end)
  end

  defp stub_response(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp ok_response(content, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls, nil)

    message =
      %{"role" => "assistant", "content" => content || ""}
      |> then(fn m -> if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m end)

    %{
      "model" => "llama3.2",
      "message" => message,
      "done" => true,
      "done_reason" => "stop",
      "total_duration" => 174_560_334,
      "load_duration" => 10_000_000,
      "prompt_eval_count" => 52,
      "prompt_eval_duration" => 100_000_000,
      "eval_count" => 18,
      "eval_duration" => 64_560_334
    }
  end

  describe "text response" do
    test "parses a simple text response" do
      stub_response(200, ok_response("Hello there!"))

      cfg = config()
      messages = [Message.user("Hi")]

      assert {:ok, %Message{role: :assistant, content: "Hello there!"} = msg} =
               Ollama.chat(messages, cfg)

      assert msg.metadata[:stop_reason] == "stop"
      assert msg.metadata[:model] == "llama3.2"
      assert msg.metadata[:total_duration] == 174_560_334
      assert msg.metadata[:eval_count] == 18
      assert msg.metadata[:eval_duration] == 64_560_334
      assert msg.metadata[:prompt_eval_count] == 52
    end

    test "handles empty content" do
      stub_response(200, ok_response(""))
      cfg = config()

      assert {:ok, %Message{content: nil}} = Ollama.chat([Message.user("Hi")], cfg)
    end
  end

  describe "system messages" do
    test "keeps system messages inline" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        system_msgs = Enum.filter(decoded["messages"], &(&1["role"] == "system"))
        assert length(system_msgs) >= 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      messages = [Message.system("Be helpful"), Message.user("Hi")]
      assert {:ok, _msg} = Ollama.chat(messages, cfg)
    end

    test "prepends instructions as system message" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        first = hd(decoded["messages"])
        assert first["role"] == "system"
        assert first["content"] == "Agent instructions"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config(instructions: "Agent instructions")
      messages = [Message.user("Hi")]
      assert {:ok, _msg} = Ollama.chat(messages, cfg)
    end
  end

  describe "tool use response" do
    test "parses tool calls with synthetic IDs" do
      tool_calls = [
        %{"function" => %{"name" => "search", "arguments" => %{"query" => "elixir"}}}
      ]

      stub_response(200, ok_response("", tool_calls: tool_calls))
      cfg = config()

      assert {:ok, %Message{tool_calls: [tc]}} =
               Ollama.chat([Message.user("Search")], cfg)

      assert %ToolCall{name: "search", arguments: %{"query" => "elixir"}} = tc
      assert tc.id == "ollama_tc_0"
    end

    test "handles tool call arguments as maps (direct)" do
      tool_calls = [
        %{"function" => %{"name" => "test", "arguments" => %{"key" => "value"}}}
      ]

      stub_response(200, ok_response("", tool_calls: tool_calls))
      cfg = config()

      assert {:ok, %Message{tool_calls: [tc]}} =
               Ollama.chat([Message.user("Test")], cfg)

      assert tc.arguments == %{"key" => "value"}
    end

    test "handles tool call arguments as JSON strings (defensive fallback)" do
      tool_calls = [
        %{"function" => %{"name" => "test", "arguments" => ~s({"key":"value"})}}
      ]

      stub_response(200, ok_response("", tool_calls: tool_calls))
      cfg = config()

      assert {:ok, %Message{tool_calls: [tc]}} =
               Ollama.chat([Message.user("Test")], cfg)

      assert tc.arguments == %{"key" => "value"}
    end
  end

  describe "sending tool results" do
    test "uses role=tool and tool_name format" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        tool_msgs = Enum.filter(decoded["messages"], &(&1["role"] == "tool"))
        assert length(tool_msgs) == 2

        [first, second] = tool_msgs
        assert first["tool_name"] == "search"
        assert first["content"] == "result 1"
        assert second["tool_name"] == "fetch"
        assert second["content"] == "result 2"

        # Should NOT have tool_call_id
        refute Map.has_key?(first, "tool_call_id")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("Done")))
      end)

      cfg = config()
      tc1 = ToolCall.new(%{id: "ollama_tc_0", name: "search", arguments: %{}})
      tc2 = ToolCall.new(%{id: "ollama_tc_1", name: "fetch", arguments: %{}})
      r1 = ToolResult.success("ollama_tc_0", "search", "result 1")
      r2 = ToolResult.success("ollama_tc_1", "fetch", "result 2")

      messages = [
        Message.user("Do both"),
        Message.assistant(nil, [tc1, tc2]),
        Message.tool_results([r1, r2])
      ]

      assert {:ok, _msg} = Ollama.chat(messages, cfg)
    end
  end

  describe "tool definitions" do
    test "wraps tool definitions in OpenAI format" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool] = decoded["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "search"
        assert tool["function"]["description"] == "Search the web"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      tools = [
        %{
          name: "search",
          description: "Search the web",
          parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
        }
      ]

      cfg = config(tools: tools)
      assert {:ok, _msg} = Ollama.chat([Message.user("Hi")], cfg)
    end
  end

  describe "request format" do
    test "sends stream: false and uses /api/chat endpoint" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["stream"] == false
        assert conn.request_path == "/api/chat"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      assert {:ok, _msg} = Ollama.chat([Message.user("Hi")], cfg)
    end
  end

  describe "error handling" do
    test "returns validation_error on 404 (model not found)" do
      stub_response(404, %{"error" => "model 'unknown' not found"})
      cfg = config()

      assert {:error, %Error{type: :validation_error}} =
               Ollama.chat([Message.user("Hi")], cfg)
    end

    test "returns validation_error on 400" do
      stub_response(400, %{"error" => "Bad request"})
      cfg = config()

      assert {:error, %Error{type: :validation_error}} =
               Ollama.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on 500" do
      stub_response(500, %{"error" => "Internal error"})
      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               Ollama.chat([Message.user("Hi")], cfg)
    end

    test "returns timeout on transport timeout" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      cfg = config()

      assert {:error, %Error{type: :timeout}} =
               Ollama.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on transport error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               Ollama.chat([Message.user("Hi")], cfg)
    end
  end

  describe "authentication" do
    test "works without API key (no auth header)" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg =
        AgentConfig.new!(
          provider: :ollama,
          model: "llama3.2",
          provider_opts: [req_options: [plug: {Req.Test, __MODULE__}, retry: false]]
        )

      assert {:ok, _msg} = Ollama.chat([Message.user("Hi")], cfg)
    end

    test "sends Bearer token when key provided" do
      Req.Test.stub(__MODULE__, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer test-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      assert {:ok, _msg} = Ollama.chat([Message.user("Hi")], cfg)
    end
  end

  describe "custom headers" do
    test "merges custom headers without losing auth" do
      Req.Test.stub(__MODULE__, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer test-key"

        [custom] = Plug.Conn.get_req_header(conn, "x-custom")
        assert custom == "custom-value"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg =
        config(
          provider_opts: [
            req_options: [
              plug: {Req.Test, __MODULE__},
              retry: false,
              headers: [{"x-custom", "custom-value"}]
            ]
          ]
        )

      assert {:ok, _msg} = Ollama.chat([Message.user("Hi")], cfg)
    end
  end

  describe "retry behavior" do
    test "retries on transient 500 and succeeds on second attempt" do
      counter = :counters.new(1, [:atomics])

      Req.Test.stub(__MODULE__, fn conn ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "Temporary"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
        end
      end)

      cfg =
        config(
          provider_opts: [
            req_options: [
              plug: {Req.Test, __MODULE__},
              retry: :transient,
              retry_delay: fn _ -> 0 end
            ]
          ]
        )

      assert {:ok, %Message{content: "OK"}} = Ollama.chat([Message.user("Hi")], cfg)
      assert :counters.get(counter, 1) == 2
    end
  end
end
