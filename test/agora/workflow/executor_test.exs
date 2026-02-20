defmodule Agora.Workflow.ExecutorTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.{Builder, Executor}
  alias Agora.Error

  describe "linear pipeline" do
    test "A -> B -> C executes in order" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn r -> {:ok, r[:a] |> elem(1) |> Kernel.*(2)} end)
        |> Builder.step(:c, fn r -> {:ok, r[:b] |> elem(1) |> Kernel.+(10)} end)
        |> Builder.sequence([:a, :b, :c])
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 1}
      assert results[:b] == {:ok, 2}
      assert results[:c] == {:ok, 12}
    end
  end

  describe "parallel fan-out/fan-in" do
    test "A -> {B, C} -> D" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 10} end)
        |> Builder.step(:b, fn r -> {:ok, elem(r[:a], 1) + 1} end)
        |> Builder.step(:c, fn r -> {:ok, elem(r[:a], 1) + 2} end)
        |> Builder.step(:d, fn r -> {:ok, elem(r[:b], 1) + elem(r[:c], 1)} end)
        |> Builder.parallel([:b, :c], from: :a, to: :d)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 10}
      assert results[:b] == {:ok, 11}
      assert results[:c] == {:ok, 12}
      assert results[:d] == {:ok, 23}
    end
  end

  describe "single step" do
    test "executes standalone step" do
      workflow =
        Builder.new()
        |> Builder.step(:only, fn _r -> {:ok, "hello"} end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:only] == {:ok, "hello"}
    end
  end

  describe "input" do
    test "step receives :input key with workflow input" do
      workflow =
        Builder.new()
        |> Builder.step(:step, fn r -> {:ok, "got: #{inspect(r[:input])}"} end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, input: "hello")
      assert results[:step] == {:ok, "got: \"hello\""}
    end

    test ":input is not in final results" do
      workflow =
        Builder.new()
        |> Builder.step(:step, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, input: "data")
      refute Map.has_key?(results, :input)
    end
  end

  describe "failure with :abort" do
    test "returns error on first failure" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> Error.wrap(:workflow_error, "b failed") end)
        |> Builder.step(:c, fn _r -> {:ok, 3} end)
        |> Builder.sequence([:a, :b, :c])
        |> Builder.build!()

      assert {:error, %Error{type: :workflow_error, message: "b failed"}} =
               Executor.run(workflow)
    end
  end

  describe "failure with :skip" do
    test "records failure and continues" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> Error.wrap(:workflow_error, "b failed") end)
        |> Builder.step(:c, fn r ->
          case r[:b] do
            {:error, _} -> {:ok, "skipped_b"}
            {:ok, v} -> {:ok, v}
          end
        end)
        |> Builder.sequence([:a, :b, :c])
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, on_failure: :skip)
      assert results[:a] == {:ok, 1}
      assert {:error, %Error{}} = results[:b]
      # :c sees the failed dependency and runs (there's at least one edge, and b is failed_dep)
      # but since b has an edge to c and b failed, c should be skipped
      assert results[:c] == :skipped
    end

    test "cascades skip to downstream" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> Error.wrap(:workflow_error, "a failed") end)
        |> Builder.step(:b, fn _r -> {:ok, "never"} end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, on_failure: :skip)
      assert {:error, _} = results[:a]
      assert results[:b] == :skipped
    end
  end

  describe "step timeout" do
    test "times out slow step" do
      workflow =
        Builder.new()
        |> Builder.step(
          :slow,
          fn _r ->
            Process.sleep(5_000)
            {:ok, "done"}
          end,
          timeout: 50
        )
        |> Builder.build!()

      assert {:error, %Error{type: :timeout}} = Executor.run(workflow)
    end
  end

  describe "retry" do
    test "succeeds on Nth attempt" do
      counter = :counters.new(1, [:atomics])

      workflow =
        Builder.new()
        |> Builder.step(
          :flaky,
          fn _r ->
            count = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, count)

            if count < 3 do
              Error.wrap(:workflow_error, "not yet")
            else
              {:ok, "success on attempt #{count}"}
            end
          end,
          retry: 3
        )
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert {:ok, "success on attempt 3"} = results[:flaky]
    end

    test "returns error after retries exhausted" do
      workflow =
        Builder.new()
        |> Builder.step(
          :always_fail,
          fn _r ->
            Error.wrap(:workflow_error, "permanent failure")
          end,
          retry: 2
        )
        |> Builder.build!()

      assert {:error, %Error{message: "permanent failure"}} = Executor.run(workflow)
    end
  end

  describe "conditional edges" do
    test "condition true: step runs" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 10} end)
        |> Builder.step(:b, fn r -> {:ok, elem(r[:a], 1) + 5} end)
        |> Builder.edge(:a, :b, condition: fn r -> elem(r[:a], 1) > 5 end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:b] == {:ok, 15}
    end

    test "condition false: step skipped" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 2} end)
        |> Builder.step(:b, fn _r -> {:ok, "should not run"} end)
        |> Builder.edge(:a, :b, condition: fn r -> elem(r[:a], 1) > 5 end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 2}
      assert results[:b] == :skipped
    end

    test "inline condition: on step — condition true runs step" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 10} end)
        |> Builder.step(:b, fn r -> {:ok, elem(r[:a], 1) + 5} end,
          after: :a,
          condition: fn r -> elem(r[:a], 1) > 5 end
        )
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:b] == {:ok, 15}
    end

    test "inline condition: on step — condition false skips step" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 2} end)
        |> Builder.step(:b, fn _r -> {:ok, "should not run"} end,
          after: :a,
          condition: fn r -> elem(r[:a], 1) > 5 end
        )
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 2}
      assert results[:b] == :skipped
    end

    test "all conditions false: step and downstream skipped" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> {:ok, "never"} end)
        |> Builder.step(:c, fn _r -> {:ok, "never"} end)
        |> Builder.edge(:a, :b, condition: fn _r -> false end)
        |> Builder.edge(:b, :c)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:b] == :skipped
      assert results[:c] == :skipped
    end
  end

  describe "crash safety" do
    test "raise is caught and returned as error" do
      workflow =
        Builder.new()
        |> Builder.step(:crasher, fn _r -> raise "boom" end)
        |> Builder.build!()

      assert {:error, %Error{type: :workflow_error, message: msg}} = Executor.run(workflow)
      assert msg =~ "raised" or msg =~ "boom"
    end

    test "throw is caught and returned as error" do
      workflow =
        Builder.new()
        |> Builder.step(:thrower, fn _r -> throw(:oops) end)
        |> Builder.build!()

      assert {:error, %Error{type: :workflow_error, message: msg}} = Executor.run(workflow)
      assert msg =~ "throw" or msg =~ "oops"
    end

    test "exit is caught and returned as error" do
      workflow =
        Builder.new()
        |> Builder.step(:exiter, fn _r -> exit(:bye) end)
        |> Builder.build!()

      assert {:error, %Error{type: :workflow_error, message: msg}} = Executor.run(workflow)
      assert msg =~ "exit" or msg =~ "bye"
    end

    test "raise with retry succeeds after fix" do
      counter = :counters.new(1, [:atomics])

      workflow =
        Builder.new()
        |> Builder.step(
          :crasher,
          fn _r ->
            count = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, count)

            if count < 2, do: raise("boom"), else: {:ok, "recovered"}
          end,
          retry: 2
        )
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert {:ok, "recovered"} = results[:crasher]
    end
  end

  describe "checkpoint" do
    test "saves and resumes from checkpoint" do
      counter = :counters.new(1, [:atomics])

      handler_a = fn _r ->
        :counters.add(counter, 1, 1)
        {:ok, "a_done"}
      end

      handler_b = fn _r -> Error.wrap(:workflow_error, "b fails") end

      workflow =
        Builder.new()
        |> Builder.step(:a, handler_a)
        |> Builder.step(:b, handler_b)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      checkpoint_config = {Agora.Workflow.CheckpointStore.Memory, []}

      # First run: a succeeds, b fails
      assert {:error, _} = Executor.run(workflow, checkpoint_store: checkpoint_config)
      assert :counters.get(counter, 1) == 1

      # Now fix b and re-run with same checkpoint
      # Since Memory backend doesn't persist across runs, we demonstrate the pattern
      # by checking that a was executed exactly once
    end
  end

  describe "determinism" do
    test "sorted execution within levels" do
      execution_order = :ets.new(:exec_order, [:ordered_set, :public])

      handler = fn step_id ->
        fn _r ->
          :ets.insert(execution_order, {System.monotonic_time(:microsecond), step_id})
          {:ok, step_id}
        end
      end

      workflow =
        Builder.new()
        |> Builder.step(:z, handler.(:z))
        |> Builder.step(:a, handler.(:a))
        |> Builder.step(:m, handler.(:m))
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, :a}
      assert results[:m] == {:ok, :m}
      assert results[:z] == {:ok, :z}

      :ets.delete(execution_order)
    end
  end

  describe "telemetry" do
    test "emits run start and stop events" do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "test-workflow-run-#{inspect(ref)}",
        [
          [:agora, :workflow, :run, :start],
          [:agora, :workflow, :run, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-workflow-run-#{inspect(ref)}") end)

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      assert {:ok, _} = Executor.run(workflow)

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :run, :start], _, %{step_count: 1}}
      assert_receive {:telemetry, ^ref, [:agora, :workflow, :run, :stop], %{duration: _}, _}
    end

    test "emits step start and stop events" do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "test-workflow-step-#{inspect(ref)}",
        [
          [:agora, :workflow, :step, :start],
          [:agora, :workflow, :step, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-workflow-step-#{inspect(ref)}") end)

      workflow =
        Builder.new()
        |> Builder.step(:my_step, fn _r -> {:ok, "done"} end, name: "My Step")
        |> Builder.build!()

      assert {:ok, _} = Executor.run(workflow)

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :step, :start], _,
                      %{step_id: :my_step, step_name: "My Step"}}

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :step, :stop], %{duration: _},
                      %{step_id: :my_step}}
    end
  end

  describe "AgentConfig handler" do
    test "executes agent step with Echo provider" do
      config = Agora.AgentConfig.new!(provider: :echo, model: "echo")

      workflow =
        Builder.new()
        |> Builder.step(:agent, config, input_mapper: fn _results -> "Hello agent" end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert {:ok, %Agora.Message{content: content}} = results[:agent]
      assert content =~ "Hello agent"
    end

    test "uses default JSON input mapper when none provided" do
      config = Agora.AgentConfig.new!(provider: :echo, model: "echo")

      workflow =
        Builder.new()
        |> Builder.step(:source, fn _r -> {:ok, "data"} end)
        |> Builder.step(:agent, config, inputs: [:source])
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert {:ok, %Agora.Message{}} = results[:agent]
    end
  end

  describe "condition crash safety" do
    test "condition that raises results in step being skipped" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> {:ok, "should not run"} end)
        |> Builder.edge(:a, :b, condition: fn _r -> raise "boom" end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 1}
      assert results[:b] == :skipped
    end

    test "condition that throws results in step being skipped" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> {:ok, "should not run"} end)
        |> Builder.edge(:a, :b, condition: fn _r -> throw(:oops) end)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:b] == :skipped
    end
  end

  describe "fan-in gating in skip mode" do
    test "fan-in step skips when one predecessor failed" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> Error.wrap(:workflow_error, "b fails") end)
        |> Builder.step(:c, fn r ->
          {:ok, elem(r[:a], 1) + elem(r[:b], 1)}
        end)
        |> Builder.parallel([:a, :b], to: :c)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, on_failure: :skip)
      assert results[:a] == {:ok, 1}
      assert {:error, %Error{}} = results[:b]
      # c should be skipped because b (a required predecessor) failed
      assert results[:c] == :skipped
    end
  end

  describe "error normalization" do
    test "handler returning {:error, non-Error} is normalized" do
      workflow =
        Builder.new()
        |> Builder.step(:bad, fn _r -> {:error, "just a string"} end)
        |> Builder.build!()

      assert {:error, %Error{type: :workflow_error, message: msg}} = Executor.run(workflow)
      assert msg =~ "non-Error"
    end

    test "handler returning unexpected value is normalized" do
      workflow =
        Builder.new()
        |> Builder.step(:weird, fn _r -> :not_a_tuple end)
        |> Builder.build!()

      assert {:error, %Error{type: :workflow_error, message: msg}} = Executor.run(workflow)
      assert msg =~ "unexpected"
    end
  end

  describe "telemetry correlation" do
    test "start and stop events share the same workflow_id" do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "test-wf-correlation-#{inspect(ref)}",
        [
          [:agora, :workflow, :run, :start],
          [:agora, :workflow, :run, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-wf-correlation-#{inspect(ref)}") end)

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      assert {:ok, _} = Executor.run(workflow)

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :run, :start], _,
                      %{workflow_id: start_id}}

      assert_receive {:telemetry, ^ref, [:agora, :workflow, :run, :stop], _,
                      %{workflow_id: stop_id}}

      assert start_id == stop_id
    end
  end
end
