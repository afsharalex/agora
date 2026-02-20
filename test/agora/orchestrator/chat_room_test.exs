defmodule Agora.Orchestrator.ChatRoomTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message}
  alias Agora.Orchestrator.ChatRoom

  defp init_config(opts \\ %{}) do
    Map.merge(%{agent_names: [:alice, :bob]}, opts)
  end

  describe "init/1" do
    test "sorts agent names by default" do
      {:ok, state} = ChatRoom.init(init_config())
      assert state.order == [:alice, :bob]
    end

    test "uses explicit agent_order" do
      {:ok, state} = ChatRoom.init(init_config(%{agent_order: [:bob, :alice]}))
      assert state.order == [:bob, :alice]
    end

    test "initializes empty transcript" do
      {:ok, state} = ChatRoom.init(init_config())
      assert state.transcript == []
    end

    test "accepts max_transcript_messages" do
      {:ok, state} = ChatRoom.init(init_config(%{max_transcript_messages: 5}))
      assert state.max_transcript_messages == 5
    end

    test "errors on empty agents" do
      assert {:error, %Error{type: :orchestration_error}} =
               ChatRoom.init(%{agent_names: [], agent_order: []})
    end
  end

  describe "next/2" do
    test "sends original input on first turn" do
      {:ok, state} = ChatRoom.init(init_config())
      input = Message.user("Hello everyone")
      context = %{original_input: input, history: []}

      assert {:next, :alice, ^input, new_state} = ChatRoom.next(state, context)
      assert new_state.index == 1
    end

    test "sends transcript as user message on subsequent turns" do
      {:ok, state} = ChatRoom.init(init_config())
      state = %{state | index: 1, transcript: [%{speaker: :alice, content: "Hi from Alice"}]}
      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, :bob, msg, _state} = ChatRoom.next(state, context)
      assert msg.role == :user
      assert msg.content == "[alice]: Hi from Alice"
    end

    test "builds multi-entry transcript" do
      {:ok, state} = ChatRoom.init(init_config())

      state = %{
        state
        | index: 2,
          transcript: [
            %{speaker: :alice, content: "Hi from Alice"},
            %{speaker: :bob, content: "Hi from Bob"}
          ]
      }

      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, :alice, msg, _state} = ChatRoom.next(state, context)
      assert msg.content == "[alice]: Hi from Alice\n\n[bob]: Hi from Bob"
    end

    test "cycles through agents" do
      {:ok, state} = ChatRoom.init(init_config())
      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, :alice, _, state} = ChatRoom.next(state, context)

      state = %{state | transcript: [%{speaker: :alice, content: "Alice here"}]}
      assert {:next, :bob, _, _state} = ChatRoom.next(state, context)
    end
  end

  describe "handle_result/3" do
    test "appends to transcript on success" do
      {:ok, state} = ChatRoom.init(init_config())
      msg = Message.assistant("Alice speaking")

      assert {:continue, new_state} = ChatRoom.handle_result(state, :alice, {:ok, msg})
      assert [%{speaker: :alice, content: "Alice speaking"}] = new_state.transcript
    end

    test "handles nil content" do
      {:ok, state} = ChatRoom.init(init_config())
      msg = Message.assistant(nil, [])

      assert {:continue, new_state} = ChatRoom.handle_result(state, :alice, {:ok, msg})
      assert [%{speaker: :alice, content: ""}] = new_state.transcript
    end

    test "propagates errors" do
      {:ok, state} = ChatRoom.init(init_config())
      error = Error.new(:provider_error, "fail")

      assert {:error, ^error, _state} = ChatRoom.handle_result(state, :alice, {:error, error})
    end
  end

  describe "max_transcript_messages" do
    test "truncates oldest entries when over limit" do
      {:ok, state} = ChatRoom.init(init_config(%{max_transcript_messages: 2}))

      state = %{
        state
        | index: 3,
          transcript: [
            %{speaker: :alice, content: "msg 1"},
            %{speaker: :bob, content: "msg 2"},
            %{speaker: :alice, content: "msg 3"}
          ]
      }

      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, _agent, msg, _state} = ChatRoom.next(state, context)
      # Should only contain last 2 entries
      assert msg.content == "[bob]: msg 2\n\n[alice]: msg 3"
    end

    test "no truncation when under limit" do
      {:ok, state} = ChatRoom.init(init_config(%{max_transcript_messages: 5}))

      state = %{
        state
        | index: 2,
          transcript: [
            %{speaker: :alice, content: "msg 1"},
            %{speaker: :bob, content: "msg 2"}
          ]
      }

      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, _agent, msg, _state} = ChatRoom.next(state, context)
      assert msg.content == "[alice]: msg 1\n\n[bob]: msg 2"
    end

    test "no truncation when nil (default)" do
      {:ok, state} = ChatRoom.init(init_config())

      state = %{
        state
        | index: 3,
          transcript: [
            %{speaker: :alice, content: "msg 1"},
            %{speaker: :bob, content: "msg 2"},
            %{speaker: :alice, content: "msg 3"}
          ]
      }

      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, _agent, msg, _state} = ChatRoom.next(state, context)
      assert msg.content =~ "msg 1"
      assert msg.content =~ "msg 2"
      assert msg.content =~ "msg 3"
    end
  end
end
