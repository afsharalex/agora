defmodule Agora.Execution.OptionPropagationTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, CancelToken, ContextPolicy, Error, Message}
  alias Agora.Orchestrator.TerminationCondition

  describe "cancel_token propagation" do
    test "token passed to run_mode, cancelled mid-run, returns :cancelled" do
      token = CancelToken.new()
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count >= 1 do
                CancelToken.cancel(token)
              end

              {:ok, Message.assistant("Response #{count}")}
            end
          ]
        )

      result =
        Agora.run_mode(:round_robin, "hello",
          agents: %{a: config, b: config},
          cancel_token: token,
          max_turns: 100
        )

      assert {:error, %Error{type: :cancelled}} = result
    end
  end

  describe "context_policy propagation" do
    test "context_policy option accepted by run_mode" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)

      {:ok, %Message{}} =
        Agora.run_mode(:single, "hello",
          agents: %{agent: config},
          context_policy: policy
        )
    end

    test "sliding_window policy limits messages seen by provider" do
      test_pid = self()
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              # On call 3+, report message count to test process
              if count >= 2 do
                # Count non-system messages to see the effect of compaction
                non_system = Enum.reject(messages, &(&1.role == :system))
                send(test_pid, {:message_count, length(non_system)})
              end

              {:ok, Message.assistant("Response #{count}")}
            end
          ]
        )

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)

      termination =
        Agora.Orchestrator.TerminationCondition.max_turns(3)

      {:ok, _} =
        Agora.run_mode(:round_robin, "hello",
          agents: %{a: config, b: config},
          context_policy: policy,
          termination: termination
        )

      # By the 3rd call, without compaction there would be 5+ messages
      # (system + user + assistant + user + assistant + ...).
      # With window_size: 2, the provider should see at most 2 non-system messages
      # plus the latest user message preserved by invariant.
      assert_receive {:message_count, count}
      assert count <= 4, "Expected compacted messages but got #{count}"
    end
  end

  describe "telemetry_metadata propagation" do
    test "custom metadata flows through to run-level telemetry events" do
      test_pid = self()
      ref = make_ref()
      request_id = "req-#{inspect(ref)}"

      :telemetry.attach(
        "prop-test-run-#{inspect(ref)}",
        [:agora, :orchestrator, :run, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:request_id] == request_id do
            send(test_pid, {:run_meta, metadata})
          end
        end,
        nil
      )

      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, _} =
        Agora.run_mode(:single, "hello",
          agents: %{agent: config},
          telemetry_metadata: %{request_id: request_id}
        )

      assert_receive {:run_meta, metadata}
      assert metadata.request_id == request_id
      assert metadata.orchestrator == Agora.Orchestrator.Single

      :telemetry.detach("prop-test-run-#{inspect(ref)}")
    end

    test "custom metadata flows through to step-level telemetry events" do
      test_pid = self()
      ref = make_ref()
      trace_id = "trace-#{inspect(ref)}"

      :telemetry.attach(
        "prop-test-step-#{inspect(ref)}",
        [:agora, :orchestrator, :step, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:trace_id] == trace_id do
            send(test_pid, {:step_meta, metadata})
          end
        end,
        nil
      )

      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, _} =
        Agora.run_mode(:single, "hello",
          agents: %{agent: config},
          telemetry_metadata: %{trace_id: trace_id}
        )

      assert_receive {:step_meta, metadata}
      assert metadata.trace_id == trace_id
      assert metadata.agent == :agent

      :telemetry.detach("prop-test-step-#{inspect(ref)}")
    end
  end

  describe "workflow mode options" do
    test ":dag mode passes through workflow options" do
      alias Agora.Workflow.Builder

      {:ok, workflow} =
        Builder.new()
        |> Builder.step(:step1, fn input ->
          {:ok, "processed: #{inspect(input)}"}
        end)
        |> Builder.build()

      {:ok, results} =
        Agora.run_mode(:dag, workflow,
          input: "data",
          cancel_token: CancelToken.new()
        )

      assert {:ok, _} = results[:step1]
    end

    test ":sequential mode passes cancel_token through" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      steps = [{:a, fn _r -> {:ok, "should not run"} end}]

      assert {:error, %Error{type: :cancelled}} =
               Agora.run_mode(:sequential, steps, cancel_token: token)
    end

    test ":parallel mode passes telemetry_metadata through" do
      ref = make_ref()
      parent = self()
      trace_id = "opt-prop-parallel-#{inspect(ref)}"

      :telemetry.attach(
        "opt-prop-parallel-#{inspect(ref)}",
        [:agora, :workflow, :run, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:trace_id] == trace_id do
            send(parent, {:got_meta, ref})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("opt-prop-parallel-#{inspect(ref)}") end)

      branches = [{:a, fn _r -> {:ok, 1} end}]

      {:ok, _} =
        Agora.run_mode(:parallel, branches,
          telemetry_metadata: %{trace_id: trace_id}
        )

      assert_receive {:got_meta, ^ref}
    end

    test ":conditional mode passes context_policy through to AgentConfig step" do
      test_pid = self()

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              send(test_pid, :agent_called)
              {:ok, Message.assistant("done")}
            end
          ]
        )

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 5)

      input = {
        {:router, fn _r -> {:ok, :go} end},
        [{fn _r -> true end, {:agent_step, config, input_mapper: fn _r -> "Hello" end}}]
      }

      {:ok, _} = Agora.run_mode(:conditional, input, context_policy: policy)

      assert_receive :agent_called
    end
  end

  describe "combined options" do
    test "cancel_token + telemetry_metadata + termination together" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      token = CancelToken.new()

      {:ok, %Message{}} =
        Agora.run_mode(:round_robin, "hello",
          agents: %{a: config, b: config},
          cancel_token: token,
          telemetry_metadata: %{session: "test"},
          termination: TerminationCondition.max_turns(2)
        )
    end
  end
end
