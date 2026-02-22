defmodule Agora.Workflow.PatternsIntegrationTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, CancelToken, ContextPolicy, Error, Message}

  describe "sequential via run_mode with cancel_token" do
    test "cancel mid-pipeline" do
      token = CancelToken.new()

      steps = [
        {:step1,
         fn _r ->
           CancelToken.cancel(token)
           {:ok, "done"}
         end},
        {:step2, fn _r -> {:ok, "should not run"} end}
      ]

      assert {:error, %Error{type: :cancelled}} =
               Agora.Execution.run_workflow(:sequential, steps, cancel_token: token)
    end
  end

  describe "conditional via run_mode with context_policy" do
    test "agent step sees compacted messages" do
      test_pid = self()

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              send(test_pid, {:agent_messages, messages})
              {:ok, Message.assistant("done")}
            end
          ]
        )

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 5)

      input = {
        {:router, fn _r -> {:ok, :go} end},
        [{fn _r -> true end, {:agent_step, config, input_mapper: fn _r -> "Hello" end}}]
      }

      {:ok, results} = Agora.Execution.run_workflow(:conditional, input, context_policy: policy)
      assert {:ok, %Message{}} = results[:agent_step]

      # Agent was called with the context policy middleware injected
      assert_receive {:agent_messages, _messages}
    end
  end

  describe "parallel via run_mode with telemetry_metadata" do
    test "metadata present in workflow events" do
      ref = make_ref()
      parent = self()
      trace_id = "int-trace-#{inspect(ref)}"

      :telemetry.attach_many(
        "int-test-meta-#{inspect(ref)}",
        [
          [:agora, :workflow, :run, :start],
          [:agora, :workflow, :step, :start]
        ],
        fn event, _measurements, metadata, _config ->
          if metadata[:trace_id] == trace_id do
            send(parent, {:telemetry, ref, event, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("int-test-meta-#{inspect(ref)}") end)

      branches = [
        {:a, fn _r -> {:ok, 1} end},
        {:b, fn _r -> {:ok, 2} end}
      ]

      {:ok, _results} =
        Agora.Execution.run_workflow(:parallel, branches,
          from: {:src, fn _r -> {:ok, 0} end},
          telemetry_metadata: %{trace_id: trace_id}
        )

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :run, :start], %{trace_id: ^trace_id}}

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :step, :start],
                      %{trace_id: ^trace_id}}
    end
  end

  describe "conditional branch-merge with nested workflow" do
    test "nested workflow runs inside branch handler" do
      inner_steps = [
        {:inner_a, fn _r -> {:ok, "inner_result"} end}
      ]

      input = {
        {:router, fn _r -> {:ok, :go} end},
        [
          {fn _r -> true end,
           {:branch,
            fn _r ->
              {:ok, inner} = Agora.Workflow.Patterns.sequential(inner_steps)
              {:ok, inner_results} = Agora.run_workflow(inner)
              {:ok, elem(inner_results[:inner_a], 1)}
            end}}
        ]
      }

      {:ok, results} =
        Agora.Execution.run_workflow(:conditional, input,
          merge:
            {:final,
             fn r ->
               {:ok, "merged: #{elem(r[:branch], 1)}"}
             end}
        )

      assert results[:branch] == {:ok, "inner_result"}
      assert {:ok, "merged: inner_result"} = results[:final]
    end
  end

  describe "full cross-cutting propagation" do
    test "cancel + policy + telemetry together" do
      ref = make_ref()
      parent = self()
      trace_id = "full-xcut-#{inspect(ref)}"
      token = CancelToken.new()
      policy = ContextPolicy.new!(strategy: :none)

      :telemetry.attach(
        "full-xcut-#{inspect(ref)}",
        [:agora, :workflow, :run, :start],
        fn _event, _measurements, metadata, _config ->
          if metadata[:trace_id] == trace_id do
            send(parent, {:run_started, ref, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("full-xcut-#{inspect(ref)}") end)

      steps = [
        {:a, fn _r -> {:ok, "done"} end}
      ]

      {:ok, results} =
        Agora.Execution.run_workflow(:sequential, steps,
          cancel_token: token,
          context_policy: policy,
          telemetry_metadata: %{trace_id: trace_id}
        )

      assert results[:a] == {:ok, "done"}
      assert_receive {:run_started, ^ref, %{trace_id: ^trace_id}}
    end
  end

  describe "cancellation under :skip + multi-level" do
    test "terminal behavior end-to-end via run_mode" do
      token = CancelToken.new()

      steps = [
        {:a,
         fn _r ->
           CancelToken.cancel(token)
           {:ok, "a done"}
         end},
        {:b, fn _r -> {:ok, "should not run"} end},
        {:c, fn _r -> {:ok, "should not run"} end}
      ]

      assert {:error, %Error{type: :cancelled}} =
               Agora.Execution.run_workflow(:sequential, steps,
                 cancel_token: token,
                 on_failure: :skip
               )
    end
  end
end
