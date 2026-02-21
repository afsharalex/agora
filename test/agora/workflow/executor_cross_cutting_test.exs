defmodule Agora.Workflow.ExecutorCrossCuttingTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, CancelToken, ContextPolicy, Error}
  alias Agora.Workflow.{Builder, Executor}

  describe "cancel_token — level boundary" do
    test "pre-cancelled token returns immediate error" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, "should not run"} end)
        |> Builder.build!()

      assert {:error, %Error{type: :cancelled}} =
               Executor.run(workflow, cancel_token: token)
    end

    test "cancel mid-workflow stops at next level" do
      token = CancelToken.new()

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r ->
          CancelToken.cancel(token)
          {:ok, "done"}
        end)
        |> Builder.step(:b, fn _r -> {:ok, "should not run"} end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      assert {:error, %Error{type: :cancelled}} =
               Executor.run(workflow, cancel_token: token)
    end
  end

  describe "cancel_token — task boundary" do
    test "cancel before task runs inside spawned task" do
      token = CancelToken.new()

      # Two parallel steps: first cancels, second should see cancellation
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r ->
          CancelToken.cancel(token)
          # Small sleep to let cancellation propagate
          Process.sleep(10)
          {:ok, "a_done"}
        end)
        |> Builder.step(:b, fn _r -> {:ok, "b_done"} end)
        |> Builder.step(:c, fn _r -> {:ok, "should not run"} end)
        |> Builder.sequence([:a, :c])
        |> Builder.build!()

      # b runs in parallel with a, c depends on a
      # After level 1 (a, b), level 2 (c) should see cancellation
      assert {:error, %Error{type: :cancelled}} =
               Executor.run(workflow, cancel_token: token)
    end
  end

  describe "cancel_token — retry bypass" do
    test "cancelled step with retries is not retried" do
      token = CancelToken.new()
      counter = :counters.new(1, [:atomics])

      workflow =
        Builder.new()
        |> Builder.step(
          :flaky,
          fn _r ->
            :counters.add(counter, 1, 1)
            CancelToken.cancel(token)
            {:error, Error.new(:cancelled, "Step cancelled")}
          end,
          retry: 3
        )
        |> Builder.build!()

      assert {:error, %Error{type: :cancelled}} =
               Executor.run(workflow, cancel_token: token)

      # Should have been called exactly once — no retries
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "cancel_token — terminal under :skip mode" do
    test "cancellation overrides :skip mode" do
      token = CancelToken.new()

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r ->
          CancelToken.cancel(token)
          {:error, Error.new(:cancelled, "Step cancelled")}
        end)
        |> Builder.step(:b, fn _r -> {:ok, "should not run"} end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      # Even with on_failure: :skip, cancellation is terminal
      assert {:error, %Error{type: :cancelled}} =
               Executor.run(workflow, on_failure: :skip, cancel_token: token)
    end

    test "cancellation in final level under :skip returns error" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      workflow =
        Builder.new()
        |> Builder.step(:only, fn _r -> {:ok, "won't run"} end)
        |> Builder.build!()

      assert {:error, %Error{type: :cancelled}} =
               Executor.run(workflow, on_failure: :skip, cancel_token: token)
    end
  end

  describe "cancel_token — nil (backward compat)" do
    test "no cancel_token runs normally" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn r -> {:ok, elem(r[:a], 1) + 1} end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 1}
      assert results[:b] == {:ok, 2}
    end
  end

  describe "context_policy — AgentConfig handler" do
    test "context policy injected into AgentConfig step" do
      test_pid = self()

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              send(test_pid, {:messages, messages})
              {:ok, Agora.Message.assistant("done")}
            end
          ]
        )

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)

      workflow =
        Builder.new()
        |> Builder.step(:agent, config, input_mapper: fn _r -> "Hello agent" end)
        |> Builder.build!()

      assert {:ok, _results} =
               Executor.run(workflow, context_policy: policy)

      # Verify the agent was called (policy middleware was injected)
      assert_receive {:messages, _messages}
    end

    test "nil context_policy does not add middleware" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      workflow =
        Builder.new()
        |> Builder.step(:agent, config, input_mapper: fn _r -> "Hello" end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert {:ok, %Agora.Message{}} = results[:agent]
    end

    test ":none strategy context_policy does not add middleware" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      policy = ContextPolicy.new!(strategy: :none)

      workflow =
        Builder.new()
        |> Builder.step(:agent, config, input_mapper: fn _r -> "Hello" end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, context_policy: policy)
      assert {:ok, %Agora.Message{}} = results[:agent]
    end
  end

  describe "context_policy — function handler" do
    test "context policy has no effect on function handlers" do
      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)

      workflow =
        Builder.new()
        |> Builder.step(:fn_step, fn _r -> {:ok, "pure function"} end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, context_policy: policy)
      assert results[:fn_step] == {:ok, "pure function"}
    end
  end

  describe "telemetry_metadata" do
    test "custom metadata in run-level events" do
      ref = make_ref()
      parent = self()
      request_id = "wf-req-#{inspect(ref)}"

      :telemetry.attach_many(
        "test-wf-meta-run-#{inspect(ref)}",
        [
          [:agora, :workflow, :run, :start],
          [:agora, :workflow, :run, :stop]
        ],
        fn event, measurements, metadata, _config ->
          if metadata[:request_id] == request_id do
            send(parent, {:telemetry, ref, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-wf-meta-run-#{inspect(ref)}") end)

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      assert {:ok, _} =
               Executor.run(workflow, telemetry_metadata: %{request_id: request_id})

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :run, :start], _,
                      %{request_id: ^request_id, workflow_id: _, step_count: 1}}

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :run, :stop], %{duration: _},
                      %{request_id: ^request_id}}
    end

    test "custom metadata in step-level events" do
      ref = make_ref()
      parent = self()
      trace_id = "wf-trace-#{inspect(ref)}"

      :telemetry.attach_many(
        "test-wf-meta-step-#{inspect(ref)}",
        [
          [:agora, :workflow, :step, :start],
          [:agora, :workflow, :step, :stop]
        ],
        fn event, measurements, metadata, _config ->
          if metadata[:trace_id] == trace_id do
            send(parent, {:telemetry, ref, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-wf-meta-step-#{inspect(ref)}") end)

      workflow =
        Builder.new()
        |> Builder.step(:my_step, fn _r -> {:ok, "done"} end, name: "My Step")
        |> Builder.build!()

      assert {:ok, _} =
               Executor.run(workflow, telemetry_metadata: %{trace_id: trace_id})

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :step, :start], _,
                      %{trace_id: ^trace_id, step_id: :my_step}}

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :step, :stop], %{duration: _},
                      %{trace_id: ^trace_id, step_id: :my_step}}
    end

    test "empty metadata preserves existing behavior" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-wf-no-meta-#{inspect(ref)}",
        [:agora, :workflow, :run, :start],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:meta, ref, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-wf-no-meta-#{inspect(ref)}") end)

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      assert {:ok, _} = Executor.run(workflow)

      assert_receive {:meta, ^ref, metadata}
      assert Map.has_key?(metadata, :workflow_id)
      assert Map.has_key?(metadata, :step_count)
    end
  end
end
