defmodule Agora.Provider.GeminiTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message, ToolCall, ToolResult}
  alias Agora.Provider.Gemini

  defp config(opts \\ []) do
    defaults = [
      provider: :gemini,
      model: "gemini-2.0-flash",
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

  defp ok_response(text, opts \\ []) do
    finish_reason = Keyword.get(opts, :finish_reason, "STOP")
    extra_parts = Keyword.get(opts, :extra_parts, [])

    text_parts = if text, do: [%{"text" => text}], else: []
    parts = text_parts ++ extra_parts

    %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => parts},
          "finishReason" => finish_reason
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 10,
        "candidatesTokenCount" => 5,
        "totalTokenCount" => 15
      },
      "modelVersion" => "gemini-2.0-flash"
    }
  end

  describe "text response" do
    test "parses a simple text response" do
      stub_response(200, ok_response("Hello there!"))

      cfg = config()
      messages = [Message.user("Hi")]

      assert {:ok, %Message{role: :assistant, content: "Hello there!"} = msg} =
               Gemini.chat(messages, cfg)

      assert msg.metadata[:stop_reason] == "STOP"
      assert msg.metadata[:usage] == %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      assert msg.metadata[:model] == "gemini-2.0-flash"
    end

    test "handles nil content when parts are empty" do
      response = %{
        "candidates" => [
          %{"content" => %{"role" => "model", "parts" => []}, "finishReason" => "STOP"}
        ]
      }

      stub_response(200, response)
      cfg = config()

      assert {:ok, %Message{content: nil}} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "handles missing content in response" do
      response = %{"candidates" => [%{"finishReason" => "SAFETY"}]}
      stub_response(200, response)
      cfg = config()

      assert {:ok, %Message{content: nil}} = Gemini.chat([Message.user("Hi")], cfg)
    end
  end

  describe "system instructions" do
    test "extracts system messages to systemInstruction" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["systemInstruction"] == %{
                 "role" => "user",
                 "parts" => [%{"text" => "Be helpful"}]
               }

        # System messages should not be in contents
        roles = Enum.map(decoded["contents"], & &1["role"])
        refute "system" in roles

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      messages = [Message.system("Be helpful"), Message.user("Hi")]
      assert {:ok, _msg} = Gemini.chat(messages, cfg)
    end

    test "prepends config.instructions to system instruction" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        text = get_in(decoded, ["systemInstruction", "parts", Access.at(0), "text"])
        assert text == "Agent instructions"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config(instructions: "Agent instructions")
      messages = [Message.user("Hi")]
      assert {:ok, _msg} = Gemini.chat(messages, cfg)
    end

    test "merges multiple system messages" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        text = get_in(decoded, ["systemInstruction", "parts", Access.at(0), "text"])
        assert text =~ "Instructions"
        assert text =~ "More context"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config(instructions: "Instructions")
      messages = [Message.system("More context"), Message.user("Hi")]
      assert {:ok, _msg} = Gemini.chat(messages, cfg)
    end
  end

  describe "tool use response" do
    test "parses functionCall parts with synthetic IDs" do
      extra_parts = [
        %{"functionCall" => %{"name" => "search", "args" => %{"query" => "elixir"}}}
      ]

      stub_response(200, ok_response(nil, extra_parts: extra_parts, finish_reason: "STOP"))
      cfg = config()

      assert {:ok, %Message{content: nil, tool_calls: [tc]}} =
               Gemini.chat([Message.user("Search")], cfg)

      assert %ToolCall{name: "search", arguments: %{"query" => "elixir"}} = tc
      assert String.starts_with?(tc.id, "gemini_tc_")
    end

    test "two calls to same function name with positional correlation" do
      extra_parts = [
        %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Tokyo"}}},
        %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "London"}}}
      ]

      stub_response(200, ok_response(nil, extra_parts: extra_parts))
      cfg = config()

      assert {:ok, %Message{tool_calls: [tc1, tc2]}} =
               Gemini.chat([Message.user("Weather")], cfg)

      assert tc1.name == "get_weather"
      assert tc1.arguments == %{"city" => "Tokyo"}
      assert tc2.name == "get_weather"
      assert tc2.arguments == %{"city" => "London"}

      # IDs should be different
      assert tc1.id != tc2.id
    end
  end

  describe "sending tool results" do
    test "sends functionResponse parts with free-form response object" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Find the user message containing functionResponse
        tool_msg =
          Enum.find(decoded["contents"], fn msg ->
            Enum.any?(msg["parts"], &Map.has_key?(&1, "functionResponse"))
          end)

        assert tool_msg != nil
        [fr_part] = Enum.filter(tool_msg["parts"], &Map.has_key?(&1, "functionResponse"))
        fr = fr_part["functionResponse"]
        assert fr["name"] == "search"
        assert fr["response"] == %{"result" => "found it"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("Done")))
      end)

      cfg = config()
      tc = ToolCall.new(%{id: "gemini_tc_0", name: "search", arguments: %{}})
      result = ToolResult.success("gemini_tc_0", "search", "found it")

      messages = [
        Message.user("Search"),
        Message.assistant(nil, [tc]),
        Message.tool_results([result])
      ]

      assert {:ok, _msg} = Gemini.chat(messages, cfg)
    end

    test "sends error results with error key" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        tool_msg =
          Enum.find(decoded["contents"], fn msg ->
            Enum.any?(msg["parts"], &Map.has_key?(&1, "functionResponse"))
          end)

        [fr_part] = Enum.filter(tool_msg["parts"], &Map.has_key?(&1, "functionResponse"))
        fr = fr_part["functionResponse"]
        assert fr["response"] == %{"error" => "something went wrong"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("Handled")))
      end)

      cfg = config()
      tc = ToolCall.new(%{id: "gemini_tc_0", name: "search", arguments: %{}})
      result = ToolResult.error("gemini_tc_0", "search", "something went wrong")

      messages = [
        Message.user("Search"),
        Message.assistant(nil, [tc]),
        Message.tool_results([result])
      ]

      assert {:ok, _msg} = Gemini.chat(messages, cfg)
    end
  end

  describe "tool definitions" do
    test "wraps tools in functionDeclarations" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool_group] = decoded["tools"]
        [decl] = tool_group["functionDeclarations"]
        assert decl["name"] == "search"
        assert decl["description"] == "Search the web"

        assert decl["parameters"] == %{
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
      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "formats module tools via tool_definitions" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool_group] = decoded["tools"]
        [decl] = tool_group["functionDeclarations"]
        assert decl["name"] == "calculator"
        assert is_binary(decl["description"])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config(tools: [Agora.Tool.Calculator])
      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "formats FunctionTool structs via tool_definitions" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool_group] = decoded["tools"]
        [decl] = tool_group["functionDeclarations"]
        assert decl["name"] == "greet"
        assert decl["description"] == "Says hello"

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
      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end
  end

  describe "message format" do
    test "uses parts-based format for user and model roles" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [msg] = decoded["contents"]
        assert msg["role"] == "user"
        assert msg["parts"] == [%{"text" => "Hello"}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      assert {:ok, _msg} = Gemini.chat([Message.user("Hello")], cfg)
    end

    test "merges adjacent same-role messages" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Two consecutive user messages should be merged into one
        assert length(decoded["contents"]) == 1
        [msg] = decoded["contents"]
        assert msg["role"] == "user"
        assert length(msg["parts"]) == 2

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      messages = [Message.user("Hello"), Message.user("World")]
      assert {:ok, _msg} = Gemini.chat(messages, cfg)
    end
  end

  describe "error handling" do
    test "returns auth_error on 401" do
      stub_response(401, %{"error" => %{"message" => "Invalid key"}})
      cfg = config()

      assert {:error, %Error{type: :auth_error}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end

    test "returns auth_error on 403" do
      stub_response(403, %{"error" => %{"message" => "Forbidden"}})
      cfg = config()

      assert {:error, %Error{type: :auth_error}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end

    test "returns rate_limit on 429" do
      stub_response(429, %{"error" => %{"message" => "Too many requests"}})
      cfg = config()

      assert {:error, %Error{type: :rate_limit, message: "Too many requests"}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end

    test "returns validation_error on 400" do
      stub_response(400, %{"error" => %{"message" => "Invalid request"}})
      cfg = config()

      assert {:error, %Error{type: :validation_error}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on 500" do
      stub_response(500, %{"error" => %{"message" => "Internal error"}})
      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end

    test "returns timeout on transport timeout" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      cfg = config()

      assert {:error, %Error{type: :timeout}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on transport error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end
  end

  describe "API key as query parameter" do
    test "sends API key as query param, not header" do
      Req.Test.stub(__MODULE__, fn conn ->
        # API key should be in query string
        query = conn.query_string
        assert query =~ "key=test-key"

        # Should NOT be in authorization header
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response("OK")))
      end)

      cfg = config()
      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end
  end

  describe "custom headers" do
    test "merges custom headers without losing query param auth" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.query_string =~ "key=test-key"

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

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
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

      assert {:ok, %Message{content: "OK"}} = Gemini.chat([Message.user("Hi")], cfg)
      assert :counters.get(counter, 1) == 2
    end
  end
end
