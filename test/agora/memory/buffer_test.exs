defmodule Agora.Memory.BufferTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message}
  alias Agora.Memory.Buffer

  describe "init/1" do
    test "valid config returns empty queue state" do
      assert {:ok, state} = Buffer.init(max_messages: 10)
      assert state.max == 10
      assert state.size == 0
    end

    test "missing :max_messages returns error" do
      assert {:error, %Error{type: :memory_error, message: message}} = Buffer.init([])
      assert message =~ ":max_messages is required"
    end

    test "zero :max_messages returns error" do
      assert {:error, %Error{type: :memory_error, message: message}} =
               Buffer.init(max_messages: 0)

      assert message =~ "positive integer"
    end

    test "negative :max_messages returns error" do
      assert {:error, %Error{type: :memory_error}} = Buffer.init(max_messages: -5)
    end

    test "non-integer :max_messages returns error" do
      assert {:error, %Error{type: :memory_error}} = Buffer.init(max_messages: "ten")
    end
  end

  describe "get/1" do
    test "empty buffer returns empty list" do
      {:ok, state} = Buffer.init(max_messages: 10)
      assert {:ok, []} = Buffer.get(state)
    end

    test "preserves chronological order" do
      {:ok, state} = Buffer.init(max_messages: 10)
      messages = [Message.user("first"), Message.assistant("second"), Message.user("third")]
      {:ok, state} = Buffer.save(state, messages)

      {:ok, retrieved} = Buffer.get(state)
      assert Enum.map(retrieved, & &1.content) == ["first", "second", "third"]
    end
  end

  describe "save/2" do
    test "replaces entire contents" do
      {:ok, state} = Buffer.init(max_messages: 10)
      {:ok, state} = Buffer.save(state, [Message.user("old")])

      {:ok, state} = Buffer.save(state, [Message.user("new")])
      {:ok, messages} = Buffer.get(state)

      assert length(messages) == 1
      assert hd(messages).content == "new"
    end

    test "list longer than max keeps last N" do
      {:ok, state} = Buffer.init(max_messages: 3)

      messages =
        for i <- 1..10 do
          Message.user("msg #{i}")
        end

      {:ok, state} = Buffer.save(state, messages)
      {:ok, retrieved} = Buffer.get(state)

      assert length(retrieved) == 3
      assert Enum.map(retrieved, & &1.content) == ["msg 8", "msg 9", "msg 10"]
      assert state.size == 3
    end

    test "list shorter than max keeps all" do
      {:ok, state} = Buffer.init(max_messages: 10)
      messages = [Message.user("one"), Message.assistant("two")]

      {:ok, state} = Buffer.save(state, messages)
      {:ok, retrieved} = Buffer.get(state)

      assert length(retrieved) == 2
      assert state.size == 2
    end

    test "exact capacity boundary" do
      {:ok, state} = Buffer.init(max_messages: 3)
      messages = [Message.user("a"), Message.assistant("b"), Message.user("c")]

      {:ok, state} = Buffer.save(state, messages)
      {:ok, retrieved} = Buffer.get(state)

      assert length(retrieved) == 3
      assert state.size == 3
    end

    test "empty list clears buffer" do
      {:ok, state} = Buffer.init(max_messages: 10)
      {:ok, state} = Buffer.save(state, [Message.user("hello")])

      {:ok, state} = Buffer.save(state, [])
      {:ok, retrieved} = Buffer.get(state)

      assert retrieved == []
      assert state.size == 0
    end
  end

  describe "clear/1" do
    test "resets to empty" do
      {:ok, state} = Buffer.init(max_messages: 10)
      {:ok, state} = Buffer.save(state, [Message.user("hello")])

      {:ok, state} = Buffer.clear(state)
      {:ok, messages} = Buffer.get(state)

      assert messages == []
      assert state.size == 0
    end

    test "preserves max config" do
      {:ok, state} = Buffer.init(max_messages: 42)
      {:ok, state} = Buffer.clear(state)
      assert state.max == 42
    end
  end

  describe "round-trip" do
    test "save then get returns same messages" do
      {:ok, state} = Buffer.init(max_messages: 10)

      messages = [
        Message.user("hello"),
        Message.assistant("hi there"),
        Message.user("how are you?")
      ]

      {:ok, state} = Buffer.save(state, messages)
      {:ok, retrieved} = Buffer.get(state)

      assert length(retrieved) == length(messages)

      for {orig, got} <- Enum.zip(messages, retrieved) do
        assert orig.role == got.role
        assert orig.content == got.content
      end
    end
  end
end
