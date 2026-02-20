defmodule Agora.Orchestrator.SingleTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message}
  alias Agora.Orchestrator.Single

  defp init_config(agents \\ [:helper]) do
    %{agent_names: agents}
  end

  describe "init/1" do
    test "extracts first agent name" do
      assert {:ok, %{agent: :helper}} = Single.init(init_config())
    end

    test "uses first agent when multiple provided" do
      assert {:ok, %{agent: :first}} = Single.init(init_config([:first, :second]))
    end

    test "errors when no agents" do
      assert {:error, %Error{type: :orchestration_error}} = Single.init(%{agent_names: []})
    end
  end

  describe "next/2" do
    test "routes original input to agent" do
      {:ok, state} = Single.init(init_config())
      input = Message.user("Hello")
      context = %{original_input: input, history: []}

      assert {:next, :helper, ^input, _state} = Single.next(state, context)
    end
  end

  describe "handle_result/3" do
    test "returns done on success" do
      {:ok, state} = Single.init(init_config())
      msg = Message.assistant("response")

      assert {:done, ^msg, _state} = Single.handle_result(state, :helper, {:ok, msg})
    end

    test "propagates error" do
      {:ok, state} = Single.init(init_config())
      error = Error.new(:provider_error, "fail")

      assert {:error, ^error, _state} = Single.handle_result(state, :helper, {:error, error})
    end
  end
end
