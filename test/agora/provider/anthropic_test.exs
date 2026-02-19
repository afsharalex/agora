defmodule Agora.Provider.AnthropicTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message, ToolCall, ToolResult}
  alias Agora.Provider.Anthropic

  defp config(opts \\ []) do
    defaults = [
      provider: :anthropic,
      model: "claude-sonnet-4-20250514",
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

  describe "text response" do
    test "parses a simple text response" do
      stub_response(200, %{
        "content" => [%{"type" => "text", "text" => "Hello there!"}],
        "stop_reason" => "end_turn",
        "model" => "claude-sonnet-4-20250514",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })

      cfg = config()
      messages = [Message.user("Hi")]

      assert {:ok, %Message{role: :assistant, content: "Hello there!"} = msg} =
               Anthropic.chat(messages, cfg)

      assert msg.metadata[:stop_reason] == "end_turn"
      assert msg.metadata[:usage] == %{"input_tokens" => 10, "output_tokens" => 5}
      assert msg.metadata[:model] == "claude-sonnet-4-20250514"
    end
  end

  describe "system message extraction" do
    test "extracts system messages to top-level parameter" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["system"] =~ "Be helpful"
        # System messages should not appear in the messages array
        refute Enum.any?(decoded["messages"], &(&1["role"] == "system"))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config()
      messages = [Message.system("Be helpful"), Message.user("Hi")]

      assert {:ok, _msg} = Anthropic.chat(messages, cfg)
    end

    test "prepends instructions to system text" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["system"] =~ "Agent instructions"
        assert decoded["system"] =~ "System message"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config(instructions: "Agent instructions")
      messages = [Message.system("System message"), Message.user("Hi")]

      assert {:ok, _msg} = Anthropic.chat(messages, cfg)
    end

    test "omits system key when no system text" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "system")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config()
      messages = [Message.user("Hi")]

      assert {:ok, _msg} = Anthropic.chat(messages, cfg)
    end
  end

  describe "tool use response" do
    test "parses tool use content blocks into ToolCalls" do
      stub_response(200, %{
        "content" => [
          %{"type" => "text", "text" => "Let me search for that."},
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "search",
            "input" => %{"query" => "elixir"}
          }
        ],
        "stop_reason" => "tool_use"
      })

      cfg = config()
      messages = [Message.user("Search for elixir")]

      assert {:ok, %Message{content: "Let me search for that.", tool_calls: [tc]} = msg} =
               Anthropic.chat(messages, cfg)

      assert %ToolCall{id: "toolu_123", name: "search", arguments: %{"query" => "elixir"}} = tc
      assert msg.metadata[:stop_reason] == "tool_use"
    end

    test "handles tool use only (no text)" do
      stub_response(200, %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_456",
            "name" => "calculate",
            "input" => %{"expression" => "2+2"}
          }
        ],
        "stop_reason" => "tool_use"
      })

      cfg = config()

      assert {:ok, %Message{content: nil, tool_calls: [tc]}} =
               Anthropic.chat([Message.user("Calculate 2+2")], cfg)

      assert tc.name == "calculate"
    end
  end

  describe "sending tool results" do
    test "translates tool results to user role with tool_result blocks" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Tool result message should be sent as user role
        tool_msg =
          Enum.find(decoded["messages"], fn m ->
            is_list(m["content"]) and Enum.any?(m["content"], &(&1["type"] == "tool_result"))
          end)

        assert tool_msg["role"] == "user"
        [tool_result | _] = tool_msg["content"]
        assert tool_result["type"] == "tool_result"
        assert tool_result["tool_use_id"] == "toolu_123"
        assert tool_result["content"] == "42"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "The answer is 42."}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config()
      tc = ToolCall.new(%{id: "toolu_123", name: "calculate", arguments: %{}})
      result = ToolResult.success("toolu_123", "calculate", "42")

      messages = [
        Message.user("Calculate something"),
        Message.assistant("Let me calculate.", [tc]),
        Message.tool(result)
      ]

      assert {:ok, %Message{content: "The answer is 42."}} = Anthropic.chat(messages, cfg)
    end
  end

  describe "adjacent role merging" do
    test "merges consecutive user messages" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Should be merged into one user message
        user_msgs = Enum.filter(decoded["messages"], &(&1["role"] == "user"))
        assert length(user_msgs) == 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config()
      messages = [Message.user("First"), Message.user("Second")]

      assert {:ok, _msg} = Anthropic.chat(messages, cfg)
    end

    test "merges user + tool messages into single user message" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # user text + tool result (sent as user) should merge
        msgs = decoded["messages"]
        # assistant in between prevents full merge, but the user→tool sequence should merge
        user_after_assistant = List.last(msgs)
        assert user_after_assistant["role"] == "user"
        assert is_list(user_after_assistant["content"])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config()
      tc = ToolCall.new(%{id: "toolu_1", name: "search", arguments: %{}})
      result = ToolResult.success("toolu_1", "search", "found it")

      messages = [
        Message.user("Search please"),
        Message.assistant(nil, [tc]),
        Message.tool(result),
        Message.user("Now what?")
      ]

      assert {:ok, _msg} = Anthropic.chat(messages, cfg)
    end
  end

  describe "tool definitions" do
    test "formats tool definitions with input_schema" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool] = decoded["tools"]
        assert tool["name"] == "search"
        assert tool["description"] == "Search the web"

        assert tool["input_schema"] == %{
                 "type" => "object",
                 "properties" => %{"q" => %{"type" => "string"}}
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      tools = [
        %{
          name: "search",
          description: "Search the web",
          parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
        }
      ]

      cfg = config(tools: tools)
      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "formats module tools via tool_definitions" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool] = decoded["tools"]
        assert tool["name"] == "calculator"
        assert is_binary(tool["description"])
        assert tool["input_schema"]["type"] == "object"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config(tools: [Agora.Tool.Calculator])
      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "formats FunctionTool structs via tool_definitions" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool] = decoded["tools"]
        assert tool["name"] == "greet"
        assert tool["description"] == "Says hello"
        assert tool["input_schema"] == %{"type" => "object", "properties" => %{}}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      ft =
        Agora.Tool.FunctionTool.new!(
          name: "greet",
          description: "Says hello",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn _, _ -> {:ok, "hi"} end
        )

      cfg = config(tools: [ft])
      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end
  end

  describe "error handling" do
    test "returns auth_error on 401" do
      stub_response(401, %{"error" => %{"message" => "Invalid key"}})
      cfg = config()

      assert {:error, %Error{type: :auth_error}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "returns rate_limit on 429" do
      stub_response(429, %{"error" => %{"message" => "Too many requests"}})
      cfg = config()

      assert {:error, %Error{type: :rate_limit, message: "Too many requests"}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "returns validation_error on 400" do
      stub_response(400, %{"error" => %{"message" => "Invalid request"}})
      cfg = config()

      assert {:error, %Error{type: :validation_error}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on 500" do
      stub_response(500, %{"error" => %{"message" => "Internal error"}})
      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "returns timeout on transport timeout" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      cfg = config()

      assert {:error, %Error{type: :timeout}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "returns provider_error on transport error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      cfg = config()

      assert {:error, %Error{type: :provider_error}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end
  end

  describe "max_tokens" do
    test "defaults max_tokens to 4096" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["max_tokens"] == 4096

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config()
      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "uses configured max_tokens" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["max_tokens"] == 1024

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      cfg = config(provider_opts: [max_tokens: 1024])
      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end
  end

  describe "custom headers" do
    test "merges custom headers without losing auth headers" do
      Req.Test.stub(__MODULE__, fn conn ->
        [api_key] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert api_key == "test-key"

        [custom] = Plug.Conn.get_req_header(conn, "x-custom")
        assert custom == "custom-value"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
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

      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
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
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "content" => [%{"type" => "text", "text" => "OK"}],
              "stop_reason" => "end_turn"
            })
          )
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

      assert {:ok, %Message{content: "OK"}} = Anthropic.chat([Message.user("Hi")], cfg)
      assert :counters.get(counter, 1) == 2
    end
  end
end
