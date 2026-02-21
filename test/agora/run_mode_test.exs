defmodule Agora.RunModeTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message}
  alias Agora.Orchestrator.TerminationCondition

  describe "run_mode/3 orchestrator modes" do
    test ":single mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, %Message{}} = Agora.run_mode(:single, "hello", agents: %{agent: config})
    end

    test ":round_robin mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, %Message{}} =
        Agora.run_mode(:round_robin, "hello",
          agents: %{a: config, b: config},
          termination: TerminationCondition.max_turns(2)
        )
    end

    test ":group_chat mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, %Message{}} =
        Agora.run_mode(:group_chat, "hello",
          agents: %{a: config, b: config},
          termination: TerminationCondition.max_turns(2)
        )
    end

    test ":supervisor mode" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          instructions: "You are a supervisor."
        )

      worker = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, %Message{}} =
        Agora.run_mode(:supervisor, "hello",
          agents: %{supervisor: config, worker: worker},
          orchestrator_opts: [supervisor_agent: :supervisor]
        )
    end
  end

  describe "run_mode/3 workflow modes" do
    test ":dag mode with workflow struct" do
      alias Agora.Workflow.Builder

      {:ok, workflow} =
        Builder.new()
        |> Builder.step(:greet, fn _input -> {:ok, "hello"} end)
        |> Builder.build()

      {:ok, results} = Agora.run_mode(:dag, workflow, input: "test")
      assert results[:greet] == {:ok, "hello"}
    end
  end

  describe "run_mode/3 unknown mode" do
    test "returns config_error" do
      assert {:error, %Error{type: :config_error}} =
               Agora.run_mode(:nonexistent, "hello", agents: %{})
    end
  end
end
