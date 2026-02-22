defmodule Agora.ComposeTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Compose, Error, Message}
  alias Agora.Orchestrator.TerminationCondition

  # --- Validation tests ---

  describe "validate_agents/1" do
    test "accepts valid keyword list" do
      agents = [a: config(), b: config()]
      assert {:ok, ^agents} = Compose.validate_agents(agents)
    end

    test "rejects empty list" do
      assert {:error, %Error{type: :config_error, message: msg}} = Compose.validate_agents([])
      assert msg =~ "must not be empty"
    end

    test "rejects non-keyword list" do
      assert {:error, %Error{type: :config_error}} = Compose.validate_agents([{1, config()}])
    end

    test "rejects plain map" do
      assert {:error, %Error{type: :config_error}} = Compose.validate_agents(%{a: config()})
    end

    test "rejects duplicate keys" do
      agents = [a: config(), a: config()]
      assert {:error, %Error{type: :config_error, message: msg}} = Compose.validate_agents(agents)
      assert msg =~ "duplicate keys"
      assert msg =~ ":a"
    end

    test "rejects non-AgentConfig values" do
      agents = [a: config(), b: "not a config"]
      assert {:error, %Error{type: :config_error, message: msg}} = Compose.validate_agents(agents)
      assert msg =~ "AgentConfig"
    end
  end

  # --- Workflow-backed patterns ---

  describe "sequential/3" do
    test "runs agents in sequence with Echo provider" do
      agents = [
        first: config(),
        second: config()
      ]

      {:ok, results} = Agora.sequential("Hello", agents)
      assert is_map(results)
      assert Map.has_key?(results, :first)
      assert Map.has_key?(results, :second)
    end

    test "first agent receives original input" do
      counter = :counters.new(1, [:atomics])

      first_fn = fn messages, _config ->
        :counters.add(counter, 1, 1)
        user_msg = Enum.find(messages, &(&1.role == :user))
        {:ok, Message.assistant("Got: #{user_msg.content}")}
      end

      agents = [
        first:
          AgentConfig.new!(
            provider: :echo,
            model: "echo",
            provider_opts: [echo_mode: :function, echo_function: first_fn]
          ),
        second: config()
      ]

      {:ok, _results} = Agora.sequential("Hello World", agents)
      assert :counters.get(counter, 1) == 1
    end

    test "returns error on validation failure" do
      assert {:error, %Error{type: :config_error}} = Agora.sequential("input", [])
    end

    test "passes through opts to workflow executor" do
      agents = [a: config(), b: config()]

      # cancel_token and other opts pass through without error
      {:ok, _} = Agora.sequential("test", agents)
    end
  end

  describe "parallel/3" do
    test "runs agents concurrently" do
      agents = [
        a: config(),
        b: config(),
        c: config()
      ]

      {:ok, results} = Agora.parallel("Analyze", agents)
      assert is_map(results)
      assert Map.has_key?(results, :a)
      assert Map.has_key?(results, :b)
      assert Map.has_key?(results, :c)
    end

    test "returns error on validation failure" do
      assert {:error, %Error{type: :config_error}} = Agora.parallel("input", [])
    end
  end

  # --- Orchestrator-backed patterns ---

  describe "round_robin/3" do
    test "runs agents in round-robin" do
      agents = [a: config(), b: config()]

      {:ok, %Message{}} =
        Agora.round_robin("hello", agents, termination: TerminationCondition.max_turns(2))
    end

    test "returns error on validation failure" do
      assert {:error, %Error{type: :config_error}} = Agora.round_robin("input", [])
    end
  end

  describe "group_chat/3" do
    test "runs agents in group chat" do
      agents = [a: config(), b: config()]

      {:ok, %Message{}} =
        Agora.group_chat("hello", agents, termination: TerminationCondition.max_turns(2))
    end

    test "returns error on validation failure" do
      assert {:error, %Error{type: :config_error}} = Agora.group_chat("input", [])
    end
  end

  describe "supervisor/4" do
    test "runs supervisor orchestration" do
      sup = config(instructions: "You are a supervisor.")
      worker = config()

      {:ok, %Message{}} =
        Agora.supervisor("task", {:manager, sup}, worker: worker)
    end

    test "merges orchestrator_opts preserving user values" do
      sup = config()
      worker = config()

      # User-provided orchestrator_opts should be preserved alongside supervisor_agent
      {:ok, %Message{}} =
        Agora.supervisor("task", {:manager, sup}, [worker: worker],
          orchestrator_opts: [custom_opt: :value]
        )
    end

    test "returns typed error on malformed tuple" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.supervisor("input", "not_a_tuple", worker: config())

      assert msg =~ "supervisor/4 expects"
    end

    test "works with only supervisor and no workers" do
      # An empty workers list is valid — the supervisor alone is still one agent
      {:ok, %Message{}} =
        Agora.supervisor("input", {:mgr, config()}, [])
    end
  end

  describe "plan/4" do
    test "runs plan orchestration" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok, Message.assistant("PLAN\nSTEP:1:worker:Do the task\nEND_PLAN")}

          _ ->
            {:ok, Message.assistant("REVIEW:COMPLETE:Task done")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Worker completed")}
      end

      planner =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [echo_mode: :function, echo_function: planner_fn]
        )

      worker =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [echo_mode: :function, echo_function: worker_fn]
        )

      {:ok, %Message{}} =
        Agora.plan("Build it", {:planner, planner}, worker: worker)
    end

    test "returns typed error on malformed tuple" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.plan("input", "not_a_tuple", worker: config())

      assert msg =~ "plan/4 expects"
    end

    test "plan with empty workers returns orchestrator error" do
      # Empty workers list passes validation (planner alone is 1 agent), but the
      # Plan orchestrator returns an error because it has no workers to delegate to.
      assert {:error, %Error{type: :orchestration_error}} =
               Agora.plan("input", {:planner, config()}, [])
    end
  end

  describe "handoff/3" do
    test "runs handoff orchestration" do
      agents = [triage: config(), billing: config()]

      {:ok, %Message{}} =
        Agora.handoff("route me", agents, termination: TerminationCondition.max_turns(2))
    end

    test "accepts :initial option" do
      agents = [a: config(), b: config()]

      {:ok, %Message{}} =
        Agora.handoff("input", agents,
          initial: :b,
          termination: TerminationCondition.max_turns(2)
        )
    end

    test "defaults initial to first agent" do
      agents = [first: config(), second: config()]

      {:ok, %Message{}} =
        Agora.handoff("input", agents, termination: TerminationCondition.max_turns(1))
    end

    test "returns error on validation failure" do
      assert {:error, %Error{type: :config_error}} = Agora.handoff("input", [])
    end
  end

  # --- Input type validation (no FunctionClauseError) ---

  describe "typed errors on invalid input types" do
    test "sequential/3 returns typed error for non-binary input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.sequential(123, a: config())

      assert msg =~ "binary input"
    end

    test "sequential/3 returns typed error for map agents" do
      assert {:error, %Error{type: :config_error}} =
               Agora.sequential("input", %{a: config()})
    end

    test "parallel/3 returns typed error for non-binary input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.parallel(123, a: config())

      assert msg =~ "binary input"
    end

    test "parallel/3 returns typed error for map agents" do
      assert {:error, %Error{type: :config_error}} =
               Agora.parallel("input", %{a: config()})
    end

    test "round_robin/3 returns typed error for map agents" do
      assert {:error, %Error{type: :config_error}} =
               Agora.round_robin("input", %{a: config()})
    end

    test "group_chat/3 returns typed error for map agents" do
      assert {:error, %Error{type: :config_error}} =
               Agora.group_chat("input", %{a: config()})
    end

    test "handoff/3 returns typed error for map agents" do
      assert {:error, %Error{type: :config_error}} =
               Agora.handoff("input", %{a: config()})
    end

    test "round_robin/3 returns typed error for non-binary input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.round_robin(123, a: config())

      assert msg =~ "binary input"
    end

    test "group_chat/3 returns typed error for non-binary input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.group_chat(123, a: config())

      assert msg =~ "binary input"
    end

    test "supervisor/4 returns typed error for non-binary input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.supervisor(123, {:mgr, config()}, worker: config())

      assert msg =~ "binary input"
    end

    test "plan/4 returns typed error for non-binary input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.plan(123, {:planner, config()}, worker: config())

      assert msg =~ "binary input"
    end

    test "handoff/3 returns typed error for non-binary input" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.handoff(123, a: config(), b: config())

      assert msg =~ "binary input"
    end

    test "round_robin/3 returns typed error for non-keyword opts" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.round_robin("input", [a: config()], %{bad: :map})

      assert msg =~ "opts must be a keyword list"
    end

    test "supervisor/4 returns typed error for non-keyword opts" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.supervisor("input", {:mgr, config()}, [worker: config()], %{bad: :map})

      assert msg =~ "opts must be a keyword list"
    end
  end

  # --- orchestrator_opts validation ---

  describe "orchestrator_opts validation" do
    test "supervisor/4 returns typed error for non-keyword orchestrator_opts" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.supervisor("task", {:mgr, config()}, [worker: config()],
                 orchestrator_opts: %{bad: :map}
               )

      assert msg =~ "orchestrator_opts must be a keyword list"
    end

    test "plan/4 returns typed error for non-keyword orchestrator_opts" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.plan("task", {:planner, config()}, [worker: config()],
                 orchestrator_opts: "bad"
               )

      assert msg =~ "orchestrator_opts must be a keyword list"
    end

    test "handoff/3 returns typed error for non-keyword orchestrator_opts" do
      assert {:error, %Error{type: :config_error, message: msg}} =
               Agora.handoff("task", [a: config(), b: config()], orchestrator_opts: %{bad: :map})

      assert msg =~ "orchestrator_opts must be a keyword list"
    end
  end

  # --- Sequential chaining ---

  describe "sequential output chaining" do
    test "second agent receives first agent's message content" do
      captured_input = :ets.new(:captured_input, [:set, :public])

      first_fn = fn _messages, _config ->
        {:ok, Message.assistant("First agent output")}
      end

      second_fn = fn messages, _config ->
        user_msg = Enum.find(messages, &(&1.role == :user))
        :ets.insert(captured_input, {:input, user_msg.content})
        {:ok, Message.assistant("Second done")}
      end

      agents = [
        first:
          AgentConfig.new!(
            provider: :echo,
            model: "echo",
            provider_opts: [echo_mode: :function, echo_function: first_fn]
          ),
        second:
          AgentConfig.new!(
            provider: :echo,
            model: "echo",
            provider_opts: [echo_mode: :function, echo_function: second_fn]
          )
      ]

      {:ok, _results} = Agora.sequential("Original input", agents)

      [{:input, received}] = :ets.lookup(captured_input, :input)
      assert received == "First agent output"
      :ets.delete(captured_input)
    end
  end

  # --- Cross-cutting behavior tests ---

  describe "opts passthrough parity" do
    test "sequential passes telemetry_metadata to workflow substrate" do
      test_pid = self()

      :telemetry.attach(
        "compose-seq-telem-#{inspect(self())}",
        [:agora, :workflow, :run, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:request_id] == "seq-123" do
            send(test_pid, :telemetry_received)
          end
        end,
        nil
      )

      agents = [a: config(), b: config()]

      {:ok, _} =
        Agora.sequential("test", agents, telemetry_metadata: %{request_id: "seq-123"})

      assert_receive :telemetry_received, 1000

      :telemetry.detach("compose-seq-telem-#{inspect(self())}")
    end

    test "round_robin passes telemetry_metadata to orchestrator substrate" do
      test_pid = self()

      :telemetry.attach(
        "compose-rr-telem-#{inspect(self())}",
        [:agora, :orchestrator, :run, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:request_id] == "rr-456" do
            send(test_pid, :telemetry_received)
          end
        end,
        nil
      )

      agents = [a: config(), b: config()]

      {:ok, _} =
        Agora.round_robin("test", agents,
          termination: TerminationCondition.max_turns(2),
          telemetry_metadata: %{request_id: "rr-456"}
        )

      assert_receive :telemetry_received, 1000

      :telemetry.detach("compose-rr-telem-#{inspect(self())}")
    end
  end

  # --- Helpers ---

  defp config(opts \\ []) do
    AgentConfig.new!(
      Keyword.merge(
        [provider: :echo, model: "echo"],
        opts
      )
    )
  end
end
