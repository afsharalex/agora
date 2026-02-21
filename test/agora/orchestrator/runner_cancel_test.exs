defmodule Agora.Orchestrator.RunnerCancelTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, CancelToken, ContextPolicy, Error, Message}
  alias Agora.Orchestrator.Runner

  describe "cancel_token" do
    test "cancellation mid-run returns :cancelled error" do
      token = CancelToken.new()

      # Use :function mode to cancel the token on the 2nd agent call
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
                # Cancel on 2nd call
                CancelToken.cancel(token)
              end

              {:ok, Message.assistant("Response #{count}")}
            end
          ]
        )

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: %{a: config, b: config},
          max_turns: 100,
          cancel_token: token
        )

      result = Runner.run(runner, "hello")
      assert {:error, %Error{type: :cancelled}} = result

      GenServer.stop(runner)
    end

    test "nil cancel_token is backward compatible" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: config}
        )

      {:ok, %Message{}} = Runner.run(runner, "hello")
      GenServer.stop(runner)
    end

    test "uncancelled token allows normal completion" do
      token = CancelToken.new()
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: config},
          cancel_token: token
        )

      {:ok, %Message{}} = Runner.run(runner, "hello")
      GenServer.stop(runner)
    end
  end

  describe "context_policy" do
    test "accepts context_policy option" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      policy = ContextPolicy.new!(strategy: :none)

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: config},
          context_policy: policy
        )

      {:ok, %Message{}} = Runner.run(runner, "hello")
      GenServer.stop(runner)
    end

    test "rejects invalid context_policy" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error}} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: %{agent: config},
                 context_policy: "not a policy"
               )
    end
  end

  describe "telemetry_metadata" do
    test "custom metadata merged into run-level telemetry events" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "runner-cancel-run-#{inspect(ref)}",
        [:agora, :orchestrator, :run, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:test_ref] == ref do
            send(test_pid, {:run_meta, metadata})
          end
        end,
        nil
      )

      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: config},
          telemetry_metadata: %{test_ref: ref, custom_key: "custom_value"}
        )

      {:ok, _} = Runner.run(runner, "hello")
      GenServer.stop(runner)

      assert_receive {:run_meta, metadata}
      assert metadata.custom_key == "custom_value"

      :telemetry.detach("runner-cancel-run-#{inspect(ref)}")
    end

    test "custom metadata merged into step-level telemetry events" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "runner-cancel-step-#{inspect(ref)}",
        [:agora, :orchestrator, :step, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:test_ref] == ref do
            send(test_pid, {:step_meta, metadata})
          end
        end,
        nil
      )

      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, runner} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: %{agent: config},
          telemetry_metadata: %{test_ref: ref, trace_id: "abc123"}
        )

      {:ok, _} = Runner.run(runner, "hello")
      GenServer.stop(runner)

      assert_receive {:step_meta, metadata}
      assert metadata.trace_id == "abc123"

      :telemetry.detach("runner-cancel-step-#{inspect(ref)}")
    end

    test "rejects non-map telemetry_metadata" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :config_error}} =
               Runner.start_link(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: %{agent: config},
                 telemetry_metadata: "not a map"
               )
    end
  end
end
