defmodule Agora.Provider.OpenAITest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message, ToolCall, ToolResult}
  alias Agora.Provider.OpenAI

  defp config(opts \\ []) do
    defaults = [
      provider: :openai,
      model: "gpt-4o",
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
    finish_reason = Keyword.get(opts, :finish_reason, "stop")
    tool_calls = Keyword.get(opts, :tool_calls, nil)

    message =
      %{"role" => "assistant", "content" => content}
      |> then(fn m -> if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m end)

    %{
      "choices" => [%{"message" => message, "finish_reason" => finish_reason}],
      "model" => "gpt-4o",
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }
  end

  describe "text response" do
    test "parses a simple text response" do
      stub_response(200, ok_response("Hello there!"))

      cfg = config()
      messages = [Message.user("Hi")]

      assert {:ok, %Message{role: :assistant, content: "Hello there!"} = msg} =
               OpenAI.chat(messages, cfg)

      assert msg.metadata[:stop_reason] == "stop"

      assert msg.metadata[:usage] == %{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             }

      assert msg.metadata[:model] == "gpt-4o"
    end

    test "handles nil content in response" do
      stub_response(200, ok_response(nil))

      cfg = config()
      assert {:ok, %Message{content: nil}} = OpenAI.chat([Message.user("Hi")], cfg)
    end
  end

  describe "system messages" do
    test "keeps system messages inline" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # System messages should be inline, not extracted
        system_msgs = Enum.filter(decoded["messages"], &(&1["role"] == "system"))
        assert length(system_msgs) >= 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      messages = [Message.system("Be helpful"), Message.user("Hi")]

      assert {:ok, _msg} = OpenAI.chat(messages, cfg)
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

      assert {:ok, _msg} = OpenAI.chat(messages, cfg)
    end
  end

  describe "tool use response" do
    test "parses tool calls with JSON string arguments" do
      tool_calls = [
        %{
          "id" => "call_123",
          "type" => "function",
          "function" => %{
            "name" => "search",
            "arguments" => ~s({"query":"elixir"})
          }
        }
      ]

      stub_response(200, ok_response(nil, tool_calls: tool_calls, finish_reason: "tool_calls"))

      cfg = config()

      assert {:ok, %Message{content: nil, tool_calls: [tc]}} =
               OpenAI.chat([Message.user("Search")], cfg)

      assert %ToolCall{id: "call_123", name: "search", arguments: %{"query" => "elixir"}} = tc
    end

    test "handles malformed JSON arguments gracefully" do
      tool_calls = [
        %{
          "id" => "call_456",
          "type" => "function",
          "function" => %{
            "name" => "test",
            "arguments" => "not valid json{{"
          }
        }
      ]

      stub_response(200, ok_response(nil, tool_calls: tool_calls))

      cfg = config()

      assert {:ok, %Message{tool_calls: [tc]}} =
               OpenAI.chat([Message.user("Test")], cfg)

      assert tc.arguments == %{"_raw" => "not valid json{{"}
    end

    test "handles empty arguments string" do
      tool_calls = [
        %{
          "id" => "call_789",
          "type" => "function",
          "function" => %{"name" => "no_args", "arguments" => ""}
        }
      ]

      stub_response(200, ok_response(nil, tool_calls: tool_calls))

      cfg = config()

      assert {:ok, %Message{tool_calls: [tc]}} =
               OpenAI.chat([Message.user("Test")], cfg)

      assert tc.arguments == %{}
    end
  end

  describe "sending tool results" do
    test "expands one Agora tool message into N OpenAI tool messages" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # The single Agora :tool message with 2 results should expand to 2 OpenAI tool messages
        tool_msgs = Enum.filter(decoded["messages"], &(&1["role"] == "tool"))
        assert length(tool_msgs) == 2

        [first, second] = tool_msgs
        assert first["tool_call_id"] == "call_1"
        assert first["content"] == "result 1"
        assert second["tool_call_id"] == "call_2"
        assert second["content"] == "result 2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("Done")))
      end)

      cfg = config()
      tc1 = ToolCall.new(%{id: "call_1", name: "search", arguments: %{}})
      tc2 = ToolCall.new(%{id: "call_2", name: "fetch", arguments: %{}})
      r1 = ToolResult.success("call_1", "search", "result 1")
      r2 = ToolResult.success("call_2", "fetch", "result 2")

      messages = [
        Message.user("Do both"),
        Message.assistant(nil, [tc1, tc2]),
        Message.tool_results([r1, r2])
      ]

      assert {:ok, _msg} = OpenAI.chat(messages, cfg)
    end
  end

  describe "sending tool calls" do
    test "encodes arguments as JSON strings" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assistant_msg = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))
        [tc] = assistant_msg["tool_calls"]
        assert tc["function"]["arguments"] == ~s({"q":"test"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      tc = ToolCall.new(%{id: "call_1", name: "search", arguments: %{"q" => "test"}})
      result = ToolResult.success("call_1", "search", "found it")

      messages = [
        Message.user("Search"),
        Message.assistant(nil, [tc]),
        Message.tool(result)
      ]

      assert {:ok, _msg} = OpenAI.chat(messages, cfg)
    end
  end

  describe "tool definitions" do
    test "wraps tool definitions in function type" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool] = decoded["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "search"
        assert tool["function"]["description"] == "Search the web"

        assert tool["function"]["parameters"] == %{
                 "type" => "object",
                 "properties" => %{"q" => %{"type" => "string"}}
               }

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
      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "formats module tools via tool_definitions" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool] = decoded["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "calculator"
        assert is_binary(tool["function"]["description"])
        assert tool["function"]["parameters"]["type"] == "object"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config(tools: [Agora.Tool.Calculator])
      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "formats FunctionTool structs via tool_definitions" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool] = decoded["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "greet"
        assert tool["function"]["description"] == "Says hello"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      ft =
        Agora.Tool.FunctionTool.new!(
          name: "greet",
          description: "Says hello",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _, _ -> {:ok, "hi"} end
        )

      cfg = config(tools: [ft])
      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end
  end

  describe "error handling" do
    test "returns auth_error on 401" do
      stub_response(401, %{"error" => %{"message" => "Invalid key"}})
      cfg = config()

      assert {:error, %Error{type: :auth_error}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "returns rate_limit on 429" do
      stub_response(429, %{"error" => %{"message" => "Too many requests"}})
      cfg = config()

      assert {:error, %Error{type: :rate_limit, message: "Too many requests"}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "returns validation_error on 400" do
      stub_response(400, %{"error" => %{"message" => "Invalid request"}})
      cfg = config()

      assert {:error, %Error{type: :validation_error}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on 500" do
      stub_response(500, %{"error" => %{"message" => "Internal error"}})
      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "returns timeout on transport timeout" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      cfg = config()

      assert {:error, %Error{type: :timeout}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on transport error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end
  end

  describe "auth header" do
    test "sends Bearer token in authorization header" do
      Req.Test.stub(__MODULE__, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        assert auth_header == ["Bearer test-key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end
  end

  describe "custom headers" do
    test "merges custom headers without losing auth headers" do
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

      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
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
          |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "Temporary"}}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
        end
      end)

      # Explicitly opt in to retry, use zero delay for speed
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

      assert {:ok, %Message{content: "OK"}} = OpenAI.chat([Message.user("Hi")], cfg)
      assert :counters.get(counter, 1) == 2
    end
  end
end
