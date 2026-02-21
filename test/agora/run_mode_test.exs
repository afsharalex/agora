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

    test ":sequential mode" do
      steps = [
        {:a, fn _r -> {:ok, 1} end},
        {:b, fn r -> {:ok, elem(r[:a], 1) * 2} end}
      ]

      {:ok, results} = Agora.run_mode(:sequential, steps)
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

      {:ok, results} = Agora.run_mode(:conditional, input)
      assert results[:branch_a] == {:ok, "A"}
      assert results[:branch_b] == :skipped
    end

    test ":parallel mode" do
      branches = [{:a, fn _r -> {:ok, 1} end}, {:b, fn _r -> {:ok, 2} end}]

      {:ok, results} =
        Agora.run_mode(:parallel, branches,
          from: {:src, fn _r -> {:ok, 0} end},
          to: {:sink, fn r -> {:ok, elem(r[:a], 1) + elem(r[:b], 1)} end}
        )

      assert results[:sink] == {:ok, 3}
    end

    test ":sequential with cross-cutting opts forwarded" do
      token = Agora.CancelToken.new()

      steps = [{:a, fn _r -> {:ok, "done"} end}]

      {:ok, results} = Agora.run_mode(:sequential, steps, cancel_token: token)
      assert results[:a] == {:ok, "done"}
    end
  end

  describe "run_mode/3 unknown mode" do
    test "returns config_error" do
      assert {:error, %Error{type: :config_error}} =
               Agora.run_mode(:nonexistent, "hello", agents: %{})
    end
  end
end
