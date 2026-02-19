defmodule Agora.Provider.EchoTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message, ToolCall}
  alias Agora.Provider.Echo

  defp config(opts \\ []) do
    AgentConfig.new!(Keyword.merge([provider: :echo, model: "echo"], opts))
  end

  describe "echo mode (default)" do
    test "echoes the last user message" do
      cfg = config()
      messages = [Message.user("Hello world")]

      assert {:ok, %Message{role: :assistant, content: "Echo: Hello world"}} =
               Echo.chat(messages, cfg)
    end

    test "echoes the last user message from multiple" do
      cfg = config()

      messages = [
        Message.user("First"),
        Message.assistant("Response"),
        Message.user("Second")
      ]

      assert {:ok, %Message{content: "Echo: Second"}} = Echo.chat(messages, cfg)
    end

    test "handles no user messages gracefully" do
      cfg = config()
      messages = [Message.system("Be helpful")]

      assert {:ok, %Message{content: "Echo: "}} = Echo.chat(messages, cfg)
    end
  end

  describe "static mode" do
    test "returns configured static response" do
      cfg = config(provider_opts: [echo_mode: :static, echo_response: "Fixed reply"])

      assert {:ok, %Message{content: "Fixed reply"}} =
               Echo.chat([Message.user("Anything")], cfg)
    end

    test "returns default static response" do
      cfg = config(provider_opts: [echo_mode: :static])

      assert {:ok, %Message{content: "Static response"}} =
               Echo.chat([Message.user("Anything")], cfg)
    end
  end

  describe "tool_call mode" do
    test "returns assistant message with tool calls" do
      tool_calls = [
        %{name: "search", arguments: %{"q" => "elixir"}},
        %{name: "fetch", arguments: %{"url" => "https://example.com"}}
      ]

      cfg = config(provider_opts: [echo_mode: :tool_call, echo_tool_calls: tool_calls])

      assert {:ok, %Message{content: nil, tool_calls: tcs}} =
               Echo.chat([Message.user("Find info")], cfg)

      assert length(tcs) == 2
      assert %ToolCall{name: "search", arguments: %{"q" => "elixir"}} = hd(tcs)
    end

    test "generates IDs if not provided" do
      cfg = config(provider_opts: [echo_mode: :tool_call, echo_tool_calls: [%{name: "test"}]])

      assert {:ok, %Message{tool_calls: [tc]}} = Echo.chat([Message.user("Hi")], cfg)
      assert is_binary(tc.id)
      assert tc.name == "test"
    end
  end

  describe "sequence mode" do
    test "returns responses in sequence" do
      cfg =
        config(
          provider_opts: [echo_mode: :sequence, echo_responses: ["First", "Second", "Third"]]
        )

      # No assistant messages yet → index 0
      assert {:ok, %Message{content: "First"}} = Echo.chat([Message.user("Go")], cfg)

      # One assistant message → index 1
      messages = [Message.user("Go"), Message.assistant("First"), Message.user("Next")]
      assert {:ok, %Message{content: "Second"}} = Echo.chat(messages, cfg)

      # Two assistant messages → index 2
      messages = messages ++ [Message.assistant("Second"), Message.user("More")]
      assert {:ok, %Message{content: "Third"}} = Echo.chat(messages, cfg)
    end

    test "wraps around when exhausted" do
      cfg = config(provider_opts: [echo_mode: :sequence, echo_responses: ["A", "B"]])

      messages = [
        Message.user("1"),
        Message.assistant("A"),
        Message.user("2"),
        Message.assistant("B"),
        Message.user("3")
      ]

      # 2 assistant messages, 2 responses → index 0
      assert {:ok, %Message{content: "A"}} = Echo.chat(messages, cfg)
    end
  end

  describe "error mode" do
    test "returns configured error" do
      cfg =
        config(
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :rate_limit,
            echo_error_message: "Slow down"
          ]
        )

      assert {:error, %Error{type: :rate_limit, message: "Slow down"}} =
               Echo.chat([Message.user("Hi")], cfg)
    end

    test "returns default error" do
      cfg = config(provider_opts: [echo_mode: :error])

      assert {:error, %Error{type: :provider_error, message: "Echo error"}} =
               Echo.chat([Message.user("Hi")], cfg)
    end
  end

  describe "function mode" do
    test "calls the provided function" do
      fun = fn messages, _config ->
        count = length(messages)
        {:ok, Message.assistant("Got #{count} messages")}
      end

      cfg = config(provider_opts: [echo_mode: :function, echo_function: fun])

      assert {:ok, %Message{content: "Got 2 messages"}} =
               Echo.chat([Message.user("A"), Message.user("B")], cfg)
    end

    test "returns error when no function provided" do
      cfg = config(provider_opts: [echo_mode: :function])

      assert {:error, %Error{type: :config_error}} =
               Echo.chat([Message.user("Hi")], cfg)
    end
  end

  describe "unknown mode" do
    test "returns config error" do
      cfg = config(provider_opts: [echo_mode: :banana])

      assert {:error, %Error{type: :config_error, message: "Unknown echo mode: :banana"}} =
               Echo.chat([Message.user("Hi")], cfg)
    end
  end
end
