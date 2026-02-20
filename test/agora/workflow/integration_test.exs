defmodule Agora.Workflow.IntegrationTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.{Builder, Executor}
  alias Agora.Workflow.CheckpointStore

  describe "builder + executor end-to-end" do
    test "builds and executes a multi-step pipeline" do
      workflow =
        Builder.new()
        |> Builder.step(:fetch, fn r -> {:ok, r[:input] || "default"} end)
        |> Builder.step(:upper, fn r -> {:ok, String.upcase(elem(r[:fetch], 1))} end)
        |> Builder.step(:wrap, fn r -> {:ok, "[#{elem(r[:upper], 1)}]"} end)
        |> Builder.sequence([:fetch, :upper, :wrap])
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow, input: "hello")
      assert results[:fetch] == {:ok, "hello"}
      assert results[:upper] == {:ok, "HELLO"}
      assert results[:wrap] == {:ok, "[HELLO]"}
    end
  end

  describe "conditional branching with agent steps" do
    test "branches based on condition" do
      workflow =
        Builder.new()
        |> Builder.step(:check, fn r -> {:ok, r[:input]} end)
        |> Builder.step(:path_a, fn _r -> {:ok, "took path A"} end)
        |> Builder.step(:path_b, fn _r -> {:ok, "took path B"} end)
        |> Builder.edge(:check, :path_a, condition: fn r -> elem(r[:check], 1) == "go_a" end)
        |> Builder.edge(:check, :path_b, condition: fn r -> elem(r[:check], 1) == "go_b" end)
        |> Builder.build!()

      # When input is "go_a", path_a runs, path_b skipped
      assert {:ok, results} = Executor.run(workflow, input: "go_a")
      assert results[:path_a] == {:ok, "took path A"}
      assert results[:path_b] == :skipped

      # When input is "go_b", path_b runs, path_a skipped
      assert {:ok, results} = Executor.run(workflow, input: "go_b")
      assert results[:path_a] == :skipped
      assert results[:path_b] == {:ok, "took path B"}
    end
  end

  describe "checkpoint + resume with file backend" do
    setup do
      suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
      path = Path.join(System.tmp_dir!(), "agora_integration_test_#{suffix}.json")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "resumes from checkpoint skipping completed steps", %{path: path} do
      exec_counter_a = :counters.new(1, [:atomics])
      exec_counter_b = :counters.new(1, [:atomics])

      workflow =
        Builder.new()
        |> Builder.step(:a, fn _r ->
          :counters.add(exec_counter_a, 1, 1)
          {:ok, "a_result"}
        end)
        |> Builder.step(:b, fn r ->
          :counters.add(exec_counter_b, 1, 1)
          {:ok, "b got #{elem(r[:a], 1)}"}
        end)
        |> Builder.sequence([:a, :b])
        |> Builder.build!()

      checkpoint_config = {CheckpointStore.File, path: path}

      # First run: both steps execute
      assert {:ok, results} = Executor.run(workflow, checkpoint_store: checkpoint_config)
      assert results[:a] == {:ok, "a_result"}
      assert results[:b] == {:ok, "b got a_result"}
      assert :counters.get(exec_counter_a, 1) == 1
      assert :counters.get(exec_counter_b, 1) == 1

      # Second run with same checkpoint: both should be loaded from checkpoint
      :counters.put(exec_counter_a, 1, 0)
      :counters.put(exec_counter_b, 1, 0)

      assert {:ok, results} = Executor.run(workflow, checkpoint_store: checkpoint_config)
      # Neither step was re-executed because checkpoint has both
      assert :counters.get(exec_counter_a, 1) == 0
      assert :counters.get(exec_counter_b, 1) == 0
      assert results[:a] == {:ok, "a_result"}
      assert results[:b] == {:ok, "b got a_result"}
    end
  end

  describe "auto-edge generation from inputs + execution" do
    test "inputs generate edges and execute correctly" do
      workflow =
        Builder.new()
        |> Builder.step(:source, fn _r -> {:ok, 100} end)
        |> Builder.step(:double, fn r -> {:ok, elem(r[:source], 1) * 2} end, inputs: [:source])
        |> Builder.step(:add_one, fn r -> {:ok, elem(r[:source], 1) + 1} end, inputs: [:source])
        |> Builder.step(
          :combine,
          fn r ->
            {:ok, elem(r[:double], 1) + elem(r[:add_one], 1)}
          end,
          inputs: [:double, :add_one]
        )
        |> Builder.build!()

      assert {:ok, results} = Executor.run(workflow)
      assert results[:source] == {:ok, 100}
      assert results[:double] == {:ok, 200}
      assert results[:add_one] == {:ok, 101}
      assert results[:combine] == {:ok, 301}
    end
  end

  describe "convenience API" do
    test "Agora.run_workflow/2 delegates to executor" do
      workflow =
        Builder.new()
        |> Builder.step(:greet, fn r -> {:ok, "Hello, #{r[:input]}"} end)
        |> Builder.build!()

      assert {:ok, results} = Agora.run_workflow(workflow, input: "World")
      assert results[:greet] == {:ok, "Hello, World"}
    end
  end
end
