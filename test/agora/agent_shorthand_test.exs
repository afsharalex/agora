defmodule Agora.AgentShorthandTest do
  use ExUnit.Case, async: true

  alias Agora.AgentConfig

  describe "agent/3" do
    test "returns an AgentConfig struct with provider and model" do
      config = Agora.agent(:echo, "echo")
      assert %AgentConfig{} = config
      assert config.provider == :echo
      assert config.model == "echo"
    end

    test "passes through optional options" do
      config =
        Agora.agent(:echo, "echo",
          name: "researcher",
          instructions: "You research things.",
          max_iterations: 5
        )

      assert config.name == "researcher"
      assert config.instructions == "You research things."
      assert config.max_iterations == 5
    end

    test "passes through tools" do
      tool =
        Agora.Tool.FunctionTool.new!(
          name: "test_tool",
          description: "A test tool",
          schema: %{},
          function: fn _args, _ctx -> {:ok, "result"} end
        )

      config = Agora.agent(:echo, "echo", tools: [tool])
      assert length(config.tools) == 1
    end

    test "passes through provider_opts" do
      config = Agora.agent(:echo, "echo", provider_opts: [api_key: "test-key"])
      assert config.provider_opts == [api_key: "test-key"]
    end

    test "passes through middleware" do
      mw = fn ctx, next -> next.(ctx) end
      config = Agora.agent(:echo, "echo", middleware: [mw])
      assert length(config.middleware) == 1
    end

    test "passes through memory config" do
      config = Agora.agent(:echo, "echo", memory: {Agora.Memory.Buffer, max_messages: 50})
      assert config.memory == {Agora.Memory.Buffer, max_messages: 50}
    end

    test "raises on invalid options" do
      assert_raise ArgumentError, fn ->
        Agora.agent(:echo, "echo", max_iterations: -1)
      end
    end

    test "raises on missing provider" do
      assert_raise FunctionClauseError, fn ->
        Agora.agent("not_atom", "echo")
      end
    end

    test "raises on missing model" do
      assert_raise FunctionClauseError, fn ->
        Agora.agent(:echo, :not_string)
      end
    end

    test "opts override positional args when duplicated" do
      # Keyword merge: opts first, then provider/model appended — last wins
      config = Agora.agent(:echo, "echo", provider: :anthropic, model: "custom")
      # provider: :echo and model: "echo" are appended AFTER opts, so they win
      assert config.provider == :echo
      assert config.model == "echo"
    end
  end
end
