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

    test "dispatches :plan to Plan orchestrator" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             Message.assistant(
               "PLAN\nSTEP:1:worker:Do the task\nEND_PLAN"
             )}

          _ ->
            {:ok, Message.assistant("REVIEW:COMPLETE:Task done")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Worker completed")}
      end

      planner_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [echo_mode: :function, echo_function: planner_fn]
        )

      worker_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [echo_mode: :function, echo_function: worker_fn]
        )

      {:ok, %Message{content: "Task done"}} =
        Execution.run(:plan, "Do something",
          agents: %{planner: planner_config, worker: worker_config},
          orchestrator_opts: [planner_agent: :planner]
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

  describe "run_workflow/3 — :sequential mode" do
    test "dispatches sequential with step list" do
      steps = [
        {:a, fn _r -> {:ok, 1} end},
        {:b, fn r -> {:ok, elem(r[:a], 1) + 1} end}
      ]

      {:ok, results} = Execution.run_workflow(:sequential, steps)
      assert results[:a] == {:ok, 1}
      assert results[:b] == {:ok, 2}
    end

    test "returns config_error for non-list input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Execution.run_workflow(:sequential, :not_a_list)

      assert msg =~ ":sequential mode expects a list"
    end
  end

  describe "run_workflow/3 — :conditional mode" do
    test "dispatches conditional with router and branches" do
      input = {
        {:router, fn _r -> {:ok, :go} end},
        [{fn _r -> true end, {:branch, fn _r -> {:ok, "done"} end}}]
      }

      {:ok, results} = Execution.run_workflow(:conditional, input)
      assert results[:router] == {:ok, :go}
      assert results[:branch] == {:ok, "done"}
    end

    test "returns config_error for non-tuple input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Execution.run_workflow(:conditional, "bad input")

      assert msg =~ ":conditional mode expects"
    end
  end

  describe "run_workflow/3 — :parallel mode" do
    test "dispatches parallel with step list" do
      branches = [
        {:a, fn _r -> {:ok, 1} end},
        {:b, fn _r -> {:ok, 2} end}
      ]

      {:ok, results} =
        Execution.run_workflow(:parallel, branches,
          from: {:src, fn _r -> {:ok, 0} end}
        )

      assert results[:src] == {:ok, 0}
      assert results[:a] == {:ok, 1}
      assert results[:b] == {:ok, 2}
    end

    test "returns config_error for non-list input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Execution.run_workflow(:parallel, :not_a_list)

      assert msg =~ ":parallel mode expects a list"
    end
  end

  describe "orchestrator_modes/0" do
    test "returns known orchestrator modes" do
      modes = Execution.orchestrator_modes()
      assert Map.has_key?(modes, :single)
      assert Map.has_key?(modes, :round_robin)
      assert Map.has_key?(modes, :group_chat)
      assert Map.has_key?(modes, :supervisor)
      assert Map.has_key?(modes, :plan)
    end
  end

  describe "workflow_modes/0" do
    test "returns known workflow modes" do
      modes = Execution.workflow_modes()
      assert :dag in modes
      assert :sequential in modes
      assert :conditional in modes
      assert :parallel in modes
    end
  end
end
