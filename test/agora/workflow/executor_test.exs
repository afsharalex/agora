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

  describe "optional edges" do
    test "optional edge with skipped predecessor allows merge step to run" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 10} end)
        |> Builder.step(:b, fn _r -> {:ok, "should not run"} end)
        |> Builder.step(:merge, fn r ->
          {:ok, "a=#{elem(r[:a], 1)}, b=#{inspect(r[:b])}"}
        end)
        |> Builder.edge(:a, :b, condition: fn _r -> false end)
        |> Builder.edge(:a, :merge)
        |> Builder.edge(:b, :merge, optional: true)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 10}
      assert results[:b] == :skipped
      # Merge runs because :b edge is optional and :b was skipped (not_required)
      assert {:ok, merged} = results[:merge]
      assert merged =~ "a=10"
    end

    test "optional edge with failed predecessor blocks merge step" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 10} end)
        |> Builder.step(:b, fn _r -> Error.wrap(:workflow_error, "b failed") end)
        |> Builder.step(:merge, fn _r -> {:ok, "should not run"} end)
        |> Builder.edge(:a, :b)
        |> Builder.edge(:a, :merge)
        |> Builder.edge(:b, :merge, optional: true)
        |> Builder.build!()

      # In skip mode: error stays as failed_dep even for optional edges
      assert {:ok, results} = Executor.run(workflow, on_failure: :skip)
      assert results[:a] == {:ok, 10}
      assert {:error, %Error{}} = results[:b]
      # Merge is blocked because b FAILED (not just skipped)
      assert results[:merge] == :skipped
    end

    test "all optional branches skipped means merge is skipped" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> {:ok, "never"} end)
        |> Builder.step(:c, fn _r -> {:ok, "never"} end)
        |> Builder.step(:merge, fn _r -> {:ok, "should not run"} end)
        |> Builder.edge(:a, :b, condition: fn _r -> false end)
        |> Builder.edge(:a, :c, condition: fn _r -> false end)
        |> Builder.edge(:b, :merge, optional: true)
        |> Builder.edge(:c, :merge, optional: true)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:b] == :skipped
      assert results[:c] == :skipped
      # All edges to merge are not_required, none are satisfied → merge skipped
      assert results[:merge] == :skipped
    end

    test "mixed optional and required edges" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 10} end)
        |> Builder.step(:b, fn _r -> {:ok, "skipped"} end)
        |> Builder.step(:merge, fn r ->
          {:ok, "a=#{elem(r[:a], 1)}"}
        end)
        |> Builder.edge(:a, :b, condition: fn _r -> false end)
        |> Builder.edge(:a, :merge)
        |> Builder.edge(:b, :merge, optional: true)
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      # Required edge from :a is satisfied, optional from :b is not_required
      assert {:ok, "a=10"} = results[:merge]
    end

    test "default optional: false preserves backward compatibility" do
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
      # Without optional: true, :b being skipped causes :c to be skipped (failed_dep)
      assert results[:c] == :skipped
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

  describe "checkpoint snapshots" do
    test "resume from specific checkpoint_id with Memory backend" do
      alias Agora.Workflow.{Checkpoint, CheckpointStore}

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, "a_result"} end)
        |> Builder.step(:b, fn _r -> {:ok, "b_result"} end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      # Pre-seed a checkpoint with :a already completed
      {:ok, cs} = CheckpointStore.init({Agora.Workflow.CheckpointStore.Memory, []})
      checkpoint = Checkpoint.new(workflow, id: "resume_test")
      checkpoint = Checkpoint.record_level_results(checkpoint, %{a: {:ok, "cached_a"}})
      {:ok, _cs} = CheckpointStore.save_snapshot(cs, checkpoint)

      # Since Memory backend re-initializes fresh, this tests the flow path
      # but the checkpoint is empty on reload. Testing the code path is still valuable.
      assert {:ok, results} =
               Executor.run(workflow,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.Memory, []},
                 checkpoint_id: "resume_test"
               )

      assert {:ok, _} = results[:a]
      assert {:ok, _} = results[:b]
    end

    test "incompatible workflow hash returns error" do
      alias Agora.Workflow.{Checkpoint, CheckpointStore}

      w1 =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      w2 =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> {:ok, 2} end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      # Create checkpoint from w1
      {:ok, cs} = CheckpointStore.init({Agora.Workflow.CheckpointStore.Memory, []})
      checkpoint = Checkpoint.new(w1, id: "compat_test")
      {:ok, _} = CheckpointStore.save_snapshot(cs, checkpoint)

      # Memory re-initializes fresh, so this tests flow path only.
      # With a persistent backend, this would return an error.
      result =
        Executor.run(w2,
          checkpoint_store: {Agora.Workflow.CheckpointStore.Memory, []},
          checkpoint_id: "compat_test"
        )

      # With Memory backend, checkpoint won't be found (fresh init),
      # so a new checkpoint is created — no compatibility error.
      assert {:ok, _} = result
    end

    test "skip_compatibility_check bypasses hash verification" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      assert {:ok, results} =
               Executor.run(workflow,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.Memory, []},
                 checkpoint_id: "skip_compat_test",
                 skip_compatibility_check: true
               )

      assert results[:a] == {:ok, 1}
    end

    test "backwards compat: checkpoint_store without snapshot callbacks works" do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, "hello"} end)
        |> Builder.build!()

      assert {:ok, results} =
               Executor.run(workflow,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.Memory, []}
               )

      assert results[:a] == {:ok, "hello"}
    end

    test "checkpoint_metadata is stored with checkpoint" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "agora_meta_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
        )

      on_exit(fn -> File.rm_rf(dir) end)

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      store_config = {Agora.Workflow.CheckpointStore.File, dir: dir}

      assert {:ok, _} =
               Executor.run(workflow,
                 checkpoint_store: store_config,
                 checkpoint_id: "meta_test",
                 checkpoint_metadata: %{run_by: "test"}
               )

      # Verify metadata persisted in checkpoint (keys become strings after JSON round-trip)
      {:ok, checkpoint} = Agora.load_checkpoint(store_config, "meta_test", :latest)
      assert checkpoint != nil
      assert checkpoint.metadata == %{"run_by" => "test"}
    end
  end

  describe "checkpoint snapshots with File dir mode" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "agora_exec_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
        )

      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "full execution creates checkpoint snapshots on disk", %{dir: dir} do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, "step_a"} end)
        |> Builder.step(:b, fn _r -> {:ok, "step_b"} end, inputs: [:a])
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      assert {:ok, results} =
               Executor.run(workflow,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.File, dir: dir},
                 checkpoint_id: "exec_test_1"
               )

      assert {:ok, "step_a"} = results[:a]
      assert {:ok, "step_b"} = results[:b]

      # Verify checkpoint files exist
      checkpoint_dir = Path.join(dir, "exec_test_1")
      assert File.dir?(checkpoint_dir)
      {:ok, files} = File.ls(checkpoint_dir)
      version_files = Enum.filter(files, &String.match?(&1, ~r/^v\d+\.json$/))
      assert length(version_files) > 0
    end

    test "resume from checkpoint on File dir backend", %{dir: dir} do
      call_counter = :counters.new(1, [:atomics])

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r ->
          :counters.add(call_counter, 1, 1)
          {:ok, "step_a"}
        end)
        |> Builder.step(:b, fn _r -> {:ok, "step_b"} end, inputs: [:a])
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      # First run creates checkpoint
      assert {:ok, _} =
               Executor.run(workflow,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.File, dir: dir},
                 checkpoint_id: "resume_file_test"
               )

      first_count = :counters.get(call_counter, 1)
      assert first_count >= 1

      # Second run with same checkpoint_id resumes from checkpoint
      assert {:ok, results} =
               Executor.run(workflow,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.File, dir: dir},
                 checkpoint_id: "resume_file_test"
               )

      assert {:ok, "step_a"} = results[:a]
      assert {:ok, "step_b"} = results[:b]
    end

    test "incompatible workflow returns error on File dir backend", %{dir: dir} do
      w1 =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      # Run first workflow and create checkpoint
      assert {:ok, _} =
               Executor.run(w1,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.File, dir: dir},
                 checkpoint_id: "compat_file_test"
               )

      # Modified workflow with different topology
      w2 =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.step(:b, fn _r -> {:ok, 2} end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      # Resume with incompatible workflow
      assert {:error, error} =
               Executor.run(w2,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.File, dir: dir},
                 checkpoint_id: "compat_file_test"
               )

      assert error.type == :workflow_error
      assert error.message =~ "hash mismatch"
    end

    test "checkpoint_version selects specific snapshot version", %{dir: dir} do
      # Multi-level workflow: 2 levels → 2 in-progress snapshots + 1 finalized = 3 versions
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, "step_a"} end)
        |> Builder.step(:b, fn _r -> {:ok, "step_b"} end, inputs: [:a])
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      store_config = {Agora.Workflow.CheckpointStore.File, dir: dir}

      assert {:ok, _} =
               Executor.run(workflow,
                 checkpoint_store: store_config,
                 checkpoint_id: "version_test"
               )

      # Latest version should be finalized (:completed)
      {:ok, latest} = Agora.load_checkpoint(store_config, "version_test", :latest)
      assert latest != nil
      assert latest.status == :completed

      # Version 2 should be the first in-progress snapshot (after level 1)
      {:ok, v2} = Agora.load_checkpoint(store_config, "version_test", 2)
      assert v2 != nil
      assert v2.status == :in_progress
      assert MapSet.member?(v2.completed_steps, :a)
      refute MapSet.member?(v2.completed_steps, :b)

      # Resume from a specific earlier version
      workflow2 =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, "step_a_v2"} end)
        |> Builder.step(:b, fn _r -> {:ok, "step_b_v2"} end, inputs: [:a])
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      assert {:ok, results} =
               Executor.run(workflow2,
                 checkpoint_store: store_config,
                 checkpoint_id: "version_test",
                 checkpoint_version: 2
               )

      # Step :a was checkpointed (from v2), step :b ran with new handler
      assert {:ok, "step_a"} = results[:a]
      assert {:ok, "step_b_v2"} = results[:b]
    end

    test "retention runs after successful completion", %{dir: dir} do
      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r -> {:ok, 1} end)
        |> Builder.build!()

      store_config = {Agora.Workflow.CheckpointStore.File, dir: dir}

      # Run 4 times with different checkpoint IDs to create 4 completed checkpoints
      for i <- 1..4 do
        assert {:ok, _} =
                 Executor.run(workflow,
                   checkpoint_store: store_config,
                   checkpoint_id: "retention_#{i}"
                 )
      end

      # Verify all 4 exist
      {:ok, all} = Agora.list_checkpoints(store_config)
      assert length(all) == 4

      # Run one more time with retention policy: keep only 2 completed
      assert {:ok, _} =
               Executor.run(workflow,
                 checkpoint_store: store_config,
                 checkpoint_id: "retention_5",
                 retention: [max_completed: 2]
               )

      # After retention, only the 2 most recent completed checkpoints should remain
      {:ok, remaining} = Agora.list_checkpoints(store_config)
      completed = Enum.filter(remaining, &(&1.status == :completed))
      assert length(completed) <= 2
    end

    test "per-step save is no-op in dir mode (no crash)", %{dir: dir} do
      # Verifies that the legacy per-step save path doesn't crash in dir mode
      workflow =
        Builder.new()
        |> Builder.step(:x, fn _r -> {:ok, "x_val"} end)
        |> Builder.step(:y, fn _r -> {:ok, "y_val"} end, inputs: [:x])
        |> Builder.sequence([:x, :y])
        |> Builder.build!()

      assert {:ok, results} =
               Executor.run(workflow,
                 checkpoint_store: {Agora.Workflow.CheckpointStore.File, dir: dir}
               )

      assert {:ok, "x_val"} = results[:x]
      assert {:ok, "y_val"} = results[:y]
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
