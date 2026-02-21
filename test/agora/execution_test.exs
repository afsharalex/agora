defmodule Agora.ExecutionTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Execution, Message}

  describe "run/3 — mode dispatch" do
    test "dispatches :single to Single orchestrator" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, %Message{}} =
        Execution.run(:single, "hello", agents: %{agent: config})
    end

    test "dispatches :round_robin to RoundRobin orchestrator" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      termination =
        Agora.Orchestrator.TerminationCondition.max_turns(2)

      {:ok, %Message{}} =
        Execution.run(:round_robin, "hello",
          agents: %{a: config, b: config},
          termination: termination
        )
    end

    test "dispatches :group_chat to GroupChat orchestrator" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      termination =
        Agora.Orchestrator.TerminationCondition.max_turns(2)

      {:ok, %Message{}} =
        Execution.run(:group_chat, "hello",
          agents: %{a: config, b: config},
          termination: termination
        )
    end

    test "dispatches :supervisor to Supervisor orchestrator" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          instructions: "You are a supervisor. Delegate to worker."
        )

      worker_config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, %Message{}} =
        Execution.run(:supervisor, "hello",
          agents: %{supervisor: config, worker: worker_config},
          orchestrator_opts: [supervisor_agent: :supervisor]
        )
    end

    test "returns config_error for unknown mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      assert {:error, %Error{type: :config_error, message: msg}} =
               Execution.run(:unknown_mode, "hello", agents: %{agent: config})

      assert msg =~ "Unknown orchestrator mode"
    end

    test "returns error when :agents is empty map" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Execution.run(:single, "hello", agents: %{})

      assert msg =~ "must not be empty"
    end

    test "returns error when :agents option is missing" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Execution.run(:single, "hello", [])

      assert msg =~ "Missing required option"
    end

    test "accepts Message struct as input" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      msg = Message.user("hello")

      {:ok, %Message{}} =
        Execution.run(:single, msg, agents: %{agent: config})
    end
  end

  describe "run_workflow/3 — mode dispatch" do
    test "dispatches :dag to workflow executor" do
      # Build a simple workflow
      alias Agora.Workflow.Builder

      {:ok, workflow} =
        Builder.new()
        |> Builder.step(:greet, fn _input -> {:ok, "hello"} end)
        |> Builder.build()

      {:ok, results} = Execution.run_workflow(:dag, workflow, input: "test")
      assert results[:greet] == {:ok, "hello"}
    end

    test "dispatches :dag with workflow module" do
      # Use the struct directly since we don't have a test module
      alias Agora.Workflow.Builder

      {:ok, workflow} =
        Builder.new()
        |> Builder.step(:step1, fn _input -> {:ok, 42} end)
        |> Builder.build()

      {:ok, results} = Execution.run_workflow(:dag, workflow)
      assert results[:step1] == {:ok, 42}
    end

    test "returns config_error for unknown workflow mode" do
      assert {:error, %Error{type: :config_error}} =
               Execution.run_workflow(:unknown, %{}, [])
    end
  end

  describe "orchestrator_modes/0" do
    test "returns known orchestrator modes" do
      modes = Execution.orchestrator_modes()
      assert Map.has_key?(modes, :single)
      assert Map.has_key?(modes, :round_robin)
      assert Map.has_key?(modes, :group_chat)
      assert Map.has_key?(modes, :supervisor)
    end
  end

  describe "workflow_modes/0" do
    test "returns known workflow modes" do
      assert :dag in Execution.workflow_modes()
    end
  end
end
