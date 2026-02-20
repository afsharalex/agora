defmodule Agora.Orchestrator.RoundRobinTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message}
  alias Agora.Orchestrator.RoundRobin

  defp init_config(opts \\ %{}) do
    Map.merge(%{agent_names: [:alice, :bob]}, opts)
  end

  describe "init/1" do
    test "sorts agent names by default" do
      {:ok, state} = RoundRobin.init(init_config())
      assert state.order == [:alice, :bob]
    end

    test "uses explicit agent_order when provided" do
      {:ok, state} = RoundRobin.init(init_config(%{agent_order: [:bob, :alice]}))
      assert state.order == [:bob, :alice]
    end

    test "starts at index 0" do
      {:ok, state} = RoundRobin.init(init_config())
      assert state.index == 0
    end

    test "errors on empty agents" do
      assert {:error, %Error{type: :orchestration_error}} =
               RoundRobin.init(%{agent_names: [], agent_order: []})
    end
  end

  describe "next/2" do
    test "sends original input on first turn" do
      {:ok, state} = RoundRobin.init(init_config())
      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, :alice, ^input, new_state} = RoundRobin.next(state, context)
      assert new_state.index == 1
    end

    test "cycles through agents" do
      {:ok, state} = RoundRobin.init(init_config())
      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      {:next, :alice, _, state} = RoundRobin.next(state, context)

      history = [
        %{agent: :alice, input: input, output: {:ok, Message.assistant("alice response")}}
      ]

      context = %{original_input: input, history: history}

      assert {:next, :bob, msg, _state} = RoundRobin.next(state, context)
      assert msg.content == "alice response"
      assert msg.role == :user
    end

    test "wraps around to first agent" do
      {:ok, state} = RoundRobin.init(init_config())
      input = Message.user("Hello")

      # Simulate 2 turns
      state = %{state | index: 2}

      context = %{
        original_input: input,
        history: [
          %{agent: :alice, input: input, output: {:ok, Message.assistant("a1")}},
          %{agent: :bob, input: Message.user("a1"), output: {:ok, Message.assistant("b1")}}
        ]
      }

      assert {:next, :alice, _, _} = RoundRobin.next(state, context)
    end

    test "routes previous response as user message" do
      {:ok, state} = RoundRobin.init(init_config())
      state = %{state | index: 1}
      input = Message.user("Hello")

      history = [
        %{agent: :alice, input: input, output: {:ok, Message.assistant("alice says hi")}}
      ]

      context = %{original_input: input, history: history}

      assert {:next, :bob, msg, _} = RoundRobin.next(state, context)
      assert msg.role == :user
      assert msg.content == "alice says hi"
    end

    test "handles nil content from previous response" do
      {:ok, state} = RoundRobin.init(init_config())
      state = %{state | index: 1}
      input = Message.user("Hello")

      history = [
        %{agent: :alice, input: input, output: {:ok, Message.assistant(nil, [])}}
      ]

      context = %{original_input: input, history: history}

      assert {:next, :bob, msg, _} = RoundRobin.next(state, context)
      assert msg.content == ""
    end

    test "handles error in previous turn" do
      {:ok, state} = RoundRobin.init(init_config())
      state = %{state | index: 1}
      input = Message.user("Hello")

      history = [
        %{agent: :alice, input: input, output: {:error, Error.new(:provider_error, "fail")}}
      ]

      context = %{original_input: input, history: history}

      assert {:next, :bob, msg, _} = RoundRobin.next(state, context)
      assert msg.content == ""
    end
  end

  describe "handle_result/3" do
    test "always continues on success" do
      {:ok, state} = RoundRobin.init(init_config())
      msg = Message.assistant("response")

      assert {:continue, ^state} = RoundRobin.handle_result(state, :alice, {:ok, msg})
    end

    test "errors on error" do
      {:ok, state} = RoundRobin.init(init_config())
      error = Error.new(:provider_error, "fail")

      assert {:error, ^error, _} = RoundRobin.handle_result(state, :alice, {:error, error})
    end
  end
end
