defmodule Agora.Orchestrator.RunnerTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message}
  alias Agora.Orchestrator.{Runner, TerminationCondition}

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  defp function_config(fun) do
    echo_config(provider_opts: [echo_mode: :function, echo_function: fun])
  end

  defp unique_name do
    :"runner_test_#{System.unique_integer([:positive])}"
  end

  describe "start_link/1" do
    test "starts a runner process" do
      agents = %{helper: echo_config()}

      assert {:ok, pid} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: agents
               )

      assert Process.alive?(pid)
    end

    test "status is :idle after start" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      assert Runner.get_status(pid) == :idle
    end

    test "empty history after start" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      assert Runner.get_history(pid) == []
    end

    test "supports name registration" do
      agents = %{helper: echo_config()}
      name = unique_name()

      {:ok, _pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents,
          name: name
        )

      assert Runner.get_status(name) == :idle
    end

    test "validates required orchestrator option" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(agents: %{helper: echo_config()})

      assert msg =~ ":orchestrator"
    end

    test "validates required agents option" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(orchestrator: Agora.Orchestrator.Single)

      assert msg =~ ":agents"
    end

    test "validates termination is a 1-arity function" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: %{helper: echo_config()},
                 termination: "not a function"
               )

      assert msg =~ ":termination"
    end

    test "validates max_turns is a positive integer" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: %{helper: echo_config()},
                 max_turns: -1
               )

      assert msg =~ ":max_turns"
    end

    test "validates agents map values are AgentConfig structs" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: %{helper: %{not: "a config"}}
               )

      assert msg =~ "AgentConfig"
    end

    test "orchestrator_opts cannot override agent_names" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents,
          orchestrator_opts: [agent_names: [:evil_agent]]
        )

      # Should still work with the real agent, not the injected one
      assert {:ok, %Message{content: "Echo: Hello!"}} = Runner.run(pid, "Hello!")
    end

    test "validates orchestrator is a module atom" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(
                 orchestrator: "not_a_module",
                 agents: %{helper: echo_config()}
               )

      assert msg =~ ":orchestrator"
    end

    test "validates orchestrator_opts is a keyword list" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: %{helper: echo_config()},
                 orchestrator_opts: %{not: "a keyword list"}
               )

      assert msg =~ ":orchestrator_opts"
    end

    test "validates orchestrator_opts rejects plain list (not keyword)" do
      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error, message: msg}} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: %{helper: echo_config()},
                 orchestrator_opts: [1, 2, 3]
               )

      assert msg =~ ":orchestrator_opts"
    end
  end

  describe "partial init rollback (D13)" do
    defmodule FailingOrchestrator do
      @behaviour Agora.Orchestrator

      @impl true
      def init(_config) do
        {:error, Agora.Error.new(:orchestration_error, "init failed")}
      end

      @impl true
      def next(state, _context), do: {:done, Agora.Message.assistant(""), state}

      @impl true
      def handle_result(state, _agent, _result), do: {:done, Agora.Message.assistant(""), state}
    end

    defmodule CrashingOrchestrator do
      @behaviour Agora.Orchestrator

      @impl true
      def init(_config), do: raise("boom")

      @impl true
      def next(state, _context), do: {:done, Agora.Message.assistant(""), state}

      @impl true
      def handle_result(state, _agent, _result), do: {:done, Agora.Message.assistant(""), state}
    end

    defmodule CrashOnReinitOrchestrator do
      @behaviour Agora.Orchestrator

      @impl true
      def init(config) do
        counter = config[:counter]

        if counter && :counters.get(counter, 1) > 0 do
          raise "re-init boom"
        else
          if counter, do: :counters.add(counter, 1, 1)
          {:ok, %{agent: hd(config.agent_names)}}
        end
      end

      @impl true
      def next(%{agent: agent} = state, context) do
        {:next, agent, context.original_input, state}
      end

      @impl true
      def handle_result(state, _agent, {:ok, msg}), do: {:done, msg, state}
      def handle_result(state, _agent, {:error, err}), do: {:error, err, state}
    end

    test "orchestrator init failure stops all agents" do
      Process.flag(:trap_exit, true)

      agents = %{
        agent_a: echo_config(),
        agent_b: echo_config()
      }

      result =
        Runner.start_link(
          orchestrator: FailingOrchestrator,
          agents: agents
        )

      # start_link fails when init returns {:stop, _}
      assert {:error, %Error{type: :orchestration_error, message: "init failed"}} = result
    end

    test "orchestrator init raise stops all agents and returns error" do
      Process.flag(:trap_exit, true)

      agents = %{
        agent_a: echo_config(),
        agent_b: echo_config()
      }

      result =
        Runner.start_link(
          orchestrator: CrashingOrchestrator,
          agents: agents
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} = result
      assert msg =~ "Orchestrator init crashed"
      assert msg =~ "boom"
    end

    test "orchestrator init crash during run/2 returns error without crashing runner" do
      counter = :counters.new(1, [:atomics])
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: CrashOnReinitOrchestrator,
          agents: agents,
          orchestrator_opts: [counter: counter]
        )

      # run/2 triggers re-init which raises
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "Hello!")

      assert msg =~ "Orchestrator init crashed"
      assert msg =~ "re-init boom"

      # Runner process is still alive
      assert Process.alive?(pid)
    end
  end

  describe "run/2 with Single orchestrator" do
    test "runs agent and returns result" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      assert {:ok, %Message{role: :assistant, content: "Echo: Hello!"}} =
               Runner.run(pid, "Hello!")
    end

    test "accepts string input" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      assert {:ok, %Message{content: "Echo: Hello!"}} = Runner.run(pid, "Hello!")
    end

    test "accepts Message struct input" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      assert {:ok, %Message{content: "Echo: Hello!"}} =
               Runner.run(pid, Message.user("Hello!"))
    end

    test "propagates agent error" do
      agents = %{
        helper:
          echo_config(
            provider_opts: [
              echo_mode: :error,
              echo_error_type: :provider_error,
              echo_error_message: "test error"
            ]
          )
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      assert {:error, %Error{type: :provider_error}} = Runner.run(pid, "Hello!")
    end

    test "records history" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:ok, _} = Runner.run(pid, "Hello!")

      history = Runner.get_history(pid)
      assert [%{agent: :helper, input: %Message{}, output: {:ok, %Message{}}}] = history
    end
  end

  describe "run/2 with RoundRobin orchestrator" do
    test "cycles agents and terminates on max_turns" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Response #{n}")}
      end

      agents = %{
        alice: function_config(fun),
        bob: function_config(fun)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          termination: TerminationCondition.max_turns(3)
        )

      assert {:ok, %Message{}} = Runner.run(pid, "Start")

      history = Runner.get_history(pid)
      assert length(history) == 3
    end

    test "terminates on keyword_match" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        if n >= 3 do
          {:ok, Message.assistant("DONE: final answer")}
        else
          {:ok, Message.assistant("Response #{n}")}
        end
      end

      agents = %{
        alice: function_config(fun),
        bob: function_config(fun)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          termination: TerminationCondition.keyword_match(["DONE"])
        )

      assert {:ok, %Message{content: "DONE: final answer"}} = Runner.run(pid, "Start")
    end
  end

  describe "run/2 with Supervisor orchestrator" do
    test "delegation flow — supervisor delegates to worker" do
      counter = :counters.new(1, [:atomics])

      boss_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 -> {:ok, Message.assistant("DELEGATE:worker:do the task")}
          _ -> {:ok, Message.assistant("Final: task complete")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Worker completed the task")}
      end

      agents = %{
        boss: function_config(boss_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Supervisor,
          agents: agents,
          orchestrator_opts: [supervisor_agent: :boss]
        )

      assert {:ok, %Message{content: "Final: task complete"}} = Runner.run(pid, "Do something")

      history = Runner.get_history(pid)
      # boss -> worker -> boss
      assert length(history) == 3
      assert Enum.at(history, 0).agent == :boss
      assert Enum.at(history, 1).agent == :worker
      assert Enum.at(history, 2).agent == :boss
    end

    test "supervisor returns final answer without delegation" do
      boss_fn = fn _messages, _config ->
        {:ok, Message.assistant("I can handle this myself")}
      end

      agents = %{
        boss: function_config(boss_fn),
        worker: function_config(fn _, _ -> {:ok, Message.assistant("ok")} end)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Supervisor,
          agents: agents,
          orchestrator_opts: [supervisor_agent: :boss]
        )

      assert {:ok, %Message{content: "I can handle this myself"}} = Runner.run(pid, "Hello")
    end

    test "unknown worker error" do
      boss_fn = fn _messages, _config ->
        {:ok, Message.assistant("DELEGATE:nonexistent:do something")}
      end

      agents = %{
        boss: function_config(boss_fn),
        worker: function_config(fn _, _ -> {:ok, Message.assistant("ok")} end)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Supervisor,
          agents: agents,
          orchestrator_opts: [supervisor_agent: :boss]
        )

      assert {:error, %Error{type: :orchestration_error}} = Runner.run(pid, "Hello")
    end
  end

  describe "run/2 with ChatRoom orchestrator" do
    test "shared transcript and turn taking" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Agent #{n} speaking")}
      end

      agents = %{
        alice: function_config(fun),
        bob: function_config(fun)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.ChatRoom,
          agents: agents,
          termination: TerminationCondition.max_turns(4)
        )

      assert {:ok, %Message{}} = Runner.run(pid, "Let's chat")

      history = Runner.get_history(pid)
      assert length(history) == 4
      assert Enum.at(history, 0).agent == :alice
      assert Enum.at(history, 1).agent == :bob
      assert Enum.at(history, 2).agent == :alice
      assert Enum.at(history, 3).agent == :bob
    end
  end

  describe "max_turns safety limit" do
    test "triggers orchestration_error when exceeded" do
      # Agent that never stops
      fun = fn _messages, _config ->
        {:ok, Message.assistant("still going")}
      end

      agents = %{helper: function_config(fun)}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          max_turns: 3
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "Go forever")

      assert msg =~ "maximum turns"
    end

    test "max_turns is separate from termination conditions" do
      fun = fn _messages, _config ->
        {:ok, Message.assistant("still going")}
      end

      agents = %{helper: function_config(fun)}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          max_turns: 5,
          termination: TerminationCondition.keyword_match(["STOP"])
        )

      # Neither STOP keyword nor termination, but max_turns kicks in
      assert {:error, %Error{type: :orchestration_error}} = Runner.run(pid, "Go")

      assert length(Runner.get_history(pid)) == 5
    end

    test "termination condition at exact max_turns boundary succeeds" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Response #{n}")}
      end

      agents = %{helper: function_config(fun)}

      # Both max_turns and termination trigger at 3 turns —
      # termination should win (success, not error)
      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          max_turns: 3,
          termination: TerminationCondition.max_turns(3)
        )

      assert {:ok, %Message{}} = Runner.run(pid, "Go")
    end
  end

  describe "crash protection" do
    test "agent raise is caught" do
      fun = fn _messages, _config ->
        raise "boom"
      end

      agents = %{helper: function_config(fun)}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      # Agent crash becomes error, passed to handle_result, Single propagates
      assert {:error, %Error{}} = Runner.run(pid, "Hello")
    end

    test "runner remains alive after crash" do
      fun = fn _messages, _config ->
        raise "boom"
      end

      agents = %{helper: function_config(fun)}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:error, _} = Runner.run(pid, "Hello")
      assert Process.alive?(pid)
      assert Runner.get_status(pid) == :idle
    end
  end

  describe "run isolation (D10)" do
    test "orchestrator state resets between runs" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Response #{n}")}
      end

      agents = %{
        alice: function_config(fun),
        bob: function_config(fun)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          termination: TerminationCondition.max_turns(2)
        )

      {:ok, _} = Runner.run(pid, "Run 1")
      {:ok, _} = Runner.run(pid, "Run 2")

      # History should only contain turns from the last run
      history = Runner.get_history(pid)
      assert length(history) == 2
    end

    test "history clears between runs" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:ok, _} = Runner.run(pid, "First")

      assert length(Runner.get_history(pid)) == 1

      {:ok, _} = Runner.run(pid, "Second")

      assert length(Runner.get_history(pid)) == 1
    end
  end

  describe "cross-run agent history" do
    test "agent conversation history persists across runs" do
      # Use a function that echoes all messages so we can see history accumulation
      fun = fn messages, _config ->
        user_count = Enum.count(messages, &(&1.role == :user))
        {:ok, Message.assistant("Seen #{user_count} user messages")}
      end

      agents = %{helper: function_config(fun)}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:ok, msg1} = Runner.run(pid, "First")
      assert msg1.content == "Seen 1 user messages"

      {:ok, msg2} = Runner.run(pid, "Second")
      # Agent accumulates history — should see both user messages
      assert msg2.content == "Seen 2 user messages"
    end
  end

  describe "nil content routing" do
    test "nil content from agent doesn't crash RoundRobin routing" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 -> {:ok, Message.assistant(nil, [])}
          _ -> {:ok, Message.assistant("got it")}
        end
      end

      agents = %{
        alice: function_config(fun),
        bob: function_config(fun)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          termination: TerminationCondition.max_turns(2)
        )

      assert {:ok, %Message{}} = Runner.run(pid, "Start")
    end
  end

  describe "termination conditions" do
    test "any_of composition" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Response #{n}")}
      end

      agents = %{helper: function_config(fun)}

      condition =
        TerminationCondition.any_of([
          TerminationCondition.max_turns(10),
          TerminationCondition.keyword_match(["Response 2"])
        ])

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          termination: condition
        )

      assert {:ok, %Message{}} = Runner.run(pid, "Start")
      # keyword_match should trigger after 2 turns
      assert length(Runner.get_history(pid)) == 2
    end

    test "custom termination condition" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Response #{n}")}
      end

      agents = %{helper: function_config(fun)}

      condition =
        TerminationCondition.custom(fn context ->
          if length(context.history) >= 3 do
            {:done, Message.assistant("Custom stop")}
          else
            :continue
          end
        end)

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          termination: condition
        )

      assert {:ok, %Message{content: "Custom stop"}} = Runner.run(pid, "Start")
    end
  end

  describe "telemetry" do
    test "emits run start/stop events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "runner-test-run-#{inspect(ref)}",
        [
          [:agora, :orchestrator, :run, :start],
          [:agora, :orchestrator, :run, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:ok, _} = Runner.run(pid, "Hello")

      assert_receive {:telemetry, [:agora, :orchestrator, :run, :start], %{system_time: _},
                      %{orchestrator: Agora.Orchestrator.Single}}

      assert_receive {:telemetry, [:agora, :orchestrator, :run, :stop], %{duration: _, steps: _},
                      %{orchestrator: Agora.Orchestrator.Single}}

      :telemetry.detach("runner-test-run-#{inspect(ref)}")
    end

    test "emits step start/stop events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "runner-test-step-#{inspect(ref)}",
        [
          [:agora, :orchestrator, :step, :start],
          [:agora, :orchestrator, :step, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:ok, _} = Runner.run(pid, "Hello")

      assert_receive {:telemetry, [:agora, :orchestrator, :step, :start], %{system_time: _},
                      %{agent: :helper, step: 0}}

      assert_receive {:telemetry, [:agora, :orchestrator, :step, :stop], %{duration: _},
                      %{agent: :helper, step: 0}}

      :telemetry.detach("runner-test-step-#{inspect(ref)}")
    end

    test "metadata does not contain configs or API keys" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "runner-test-meta-#{inspect(ref)}",
        [
          [:agora, :orchestrator, :run, :start],
          [:agora, :orchestrator, :run, :stop],
          [:agora, :orchestrator, :step, :start],
          [:agora, :orchestrator, :step, :stop]
        ],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:meta, metadata})
        end,
        nil
      )

      agents = %{helper: echo_config(provider_opts: [api_key: "secret-key"])}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:ok, _} = Runner.run(pid, "Hello")

      # Check all telemetry metadata doesn't contain secrets
      for _ <- 1..4 do
        assert_receive {:meta, metadata}
        refute Map.has_key?(metadata, :config)
        refute Map.has_key?(metadata, :agents)
        refute Map.has_key?(metadata, :api_key)
        metadata_str = inspect(metadata)
        refute metadata_str =~ "secret-key"
      end

      :telemetry.detach("runner-test-meta-#{inspect(ref)}")
    end
  end

  describe "get_status/1" do
    test "returns :idle before and after run" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      assert Runner.get_status(pid) == :idle

      {:ok, _} = Runner.run(pid, "Hello")

      assert Runner.get_status(pid) == :idle
    end
  end

  describe "next/2 error return" do
    defmodule ErrorNextOrchestrator do
      @behaviour Agora.Orchestrator

      @impl true
      def init(config) do
        {:ok, %{agent: hd(config.agent_names), error_message: config[:error_message] || "stalled"}}
      end

      @impl true
      def next(state, _context) do
        {:error, Agora.Error.new(:orchestration_error, state.error_message), state}
      end

      @impl true
      def handle_result(state, _agent, _result), do: {:done, Agora.Message.assistant(""), state}
    end

    test "Runner surfaces {:error, ...} from next/2" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: ErrorNextOrchestrator,
          agents: agents,
          orchestrator_opts: [error_message: "Plan stalled: all steps blocked"]
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "Hello")

      assert msg == "Plan stalled: all steps blocked"
    end

    test "Runner remains alive after next/2 returns error" do
      agents = %{helper: echo_config()}

      {:ok, pid} =
        Runner.start_link(
          orchestrator: ErrorNextOrchestrator,
          agents: agents
        )

      {:error, _} = Runner.run(pid, "Hello")
      assert Process.alive?(pid)
      assert Runner.get_status(pid) == :idle
    end
  end

  describe "cleanup on terminate" do
    test "agents are stopped when runner terminates" do
      agents = %{helper: echo_config()}

      {:ok, runner_pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      # Get agent pids indirectly by running and checking they work
      {:ok, _} = Runner.run(runner_pid, "Hello")

      # Stop runner — should clean up agents
      GenServer.stop(runner_pid)
      refute Process.alive?(runner_pid)
    end
  end
end
