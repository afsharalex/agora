defmodule Agora.ToolCallTest do
  use ExUnit.Case, async: true

  alias Agora.ToolCall

  describe "new/1" do
    test "creates a tool call with defaults" do
      tc = ToolCall.new(%{id: "call_1", name: "search"})

      assert tc.id == "call_1"
      assert tc.name == "search"
      assert tc.arguments == %{}
      assert tc.status == :pending
    end

    test "accepts arguments" do
      tc =
        ToolCall.new(%{id: "call_2", name: "fetch", arguments: %{"url" => "https://example.com"}})

      assert tc.arguments == %{"url" => "https://example.com"}
    end

    test "accepts status override" do
      tc = ToolCall.new(%{id: "call_3", name: "run", status: :running})

      assert tc.status == :running
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      tc = ToolCall.new(%{id: "call_1", name: "search", arguments: %{"q" => "elixir"}})
      json = Jason.encode!(tc)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "call_1"
      assert decoded["name"] == "search"
      assert decoded["arguments"] == %{"q" => "elixir"}
      assert decoded["status"] == "pending"
    end
  end
end
