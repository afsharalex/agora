defmodule Agora.ExecutionInternalTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Execution, Message}
  alias Agora.Orchestrator.TerminationCondition

  describe "Execution.run/3 orchestrator modes" do
    test ":single mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, %Message{}} = Execution.run(:single, "hello", agents: %{agent: config})
    end

    test ":round_robin mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, %Message{}} =
        Execution.run(:round_robin, "hello",
          agents: %{a: config, b: config},
          termination: TerminationCondition.max_turns(2)
        )
    end

    test ":group_chat mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, %Message{}} =
        Execution.run(:group_chat, "hello",
          agents: %{a: config, b: config},
          termination: TerminationCondition.max_turns(2)
        )
    end

    test ":handoff mode" do
      a_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "Routing",
           metadata: %{handoff: %{target: "worker", message: "go"}}
         )}
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Handled")}
      end

      a_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [echo_mode: :function, echo_function: a_fn]
        )

      worker_config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [echo_mode: :function, echo_function: worker_fn]
        )

      {:ok, %Message{content: "Handled"}} =
        Execution.run(:handoff, "hello",
          agents: %{triage: a_config, worker: worker_config},
          orchestrator_opts: [initial_agent: :triage]
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
        Execution.run(:supervisor, "hello",
          agents: %{supervisor: config, worker: worker},
          orchestrator_opts: [supervisor_agent: :supervisor]
        )
    end

    test "unknown mode returns config_error" do
      assert {:error, %Error{type: :config_error}} =
               Execution.run(:nonexistent, "hello", agents: %{})
    end
  end

  describe "Execution.run_workflow/3 workflow modes" do
    test ":dag mode with workflow struct" do
      alias Agora.Workflow.Builder

      {:ok, workflow} =
        Builder.new()
        |> Builder.step(:greet, fn _input -> {:ok, "hello"} end)
        |> Builder.build()

      {:ok, results} = Execution.run_workflow(:dag, workflow, input: "test")
      assert results[:greet] == {:ok, "hello"}
    end

    test ":sequential mode" do
      steps = [
        {:a, fn _r -> {:ok, 1} end},
        {:b, fn r -> {:ok, elem(r[:a], 1) * 2} end}
      ]

      {:ok, results} = Execution.run_workflow(:sequential, steps)
      assert results[:a] == {:ok, 1}
      assert results[:b] == {:ok, 2}
    end

    test ":conditional mode" do
      input = {
        {:router, fn _r -> {:ok, :go_a} end},
        [
          {fn r -> r[:router] == {:ok, :go_a} end, {:branch_a, fn _r -> {:ok, "A"} end}},
          {fn r -> r[:router] == {:ok, :go_b} end, {:branch_b, fn _r -> {:ok, "B"} end}}
        ]
      }

      {:ok, results} = Execution.run_workflow(:conditional, input)
      assert results[:branch_a] == {:ok, "A"}
      assert results[:branch_b] == :skipped
    end

    test ":parallel mode" do
      branches = [{:a, fn _r -> {:ok, 1} end}, {:b, fn _r -> {:ok, 2} end}]

      {:ok, results} =
        Execution.run_workflow(:parallel, branches,
          from: {:src, fn _r -> {:ok, 0} end},
          to: {:sink, fn r -> {:ok, elem(r[:a], 1) + elem(r[:b], 1)} end}
        )

      assert results[:sink] == {:ok, 3}
    end

    test ":sequential with cross-cutting opts forwarded" do
      token = Agora.CancelToken.new()

      steps = [{:a, fn _r -> {:ok, "done"} end}]

      {:ok, results} = Execution.run_workflow(:sequential, steps, cancel_token: token)
      assert results[:a] == {:ok, "done"}
    end

    test ":dag mode with bad input returns config_error" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Execution.run_workflow(:dag, "bad")

      assert msg =~ "run_workflow expects a %Workflow{} struct or a module atom"
    end
  end

  describe "Agora.run_workflow/2 input validation" do
    test "string input returns config_error" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.run_workflow("bad input")

      assert msg =~ "run_workflow expects a %Workflow{} struct or a module atom"
    end

    test "integer input returns config_error" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.run_workflow(42)

      assert msg =~ "run_workflow expects a %Workflow{} struct or a module atom"
    end

    test "list input returns config_error" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.run_workflow([1, 2, 3])

      assert msg =~ "run_workflow expects a %Workflow{} struct or a module atom"
    end
  end
end
