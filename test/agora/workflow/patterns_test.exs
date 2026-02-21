defmodule Agora.Workflow.PatternsTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Workflow}
  alias Agora.Workflow.{Executor, Patterns}

  describe "sequential/2" do
    test "builds linear chain A → B → C" do
      {:ok, workflow} =
        Patterns.sequential([
          {:a, fn _r -> {:ok, 1} end},
          {:b, fn r -> {:ok, elem(r[:a], 1) * 2} end},
          {:c, fn r -> {:ok, elem(r[:b], 1) + 10} end}
        ])

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 1}
      assert results[:b] == {:ok, 2}
      assert results[:c] == {:ok, 12}
    end

    test "single step (degenerate case)" do
      {:ok, workflow} =
        Patterns.sequential([{:only, fn _r -> {:ok, "solo"} end}])

      assert {:ok, results} = Executor.run(workflow)
      assert results[:only] == {:ok, "solo"}
    end

    test "step_defaults applied to all steps" do
      {:ok, workflow} =
        Patterns.sequential(
          [{:a, fn _r -> {:ok, 1} end}, {:b, fn _r -> {:ok, 2} end}],
          step_defaults: [timeout: 5_000]
        )

      assert %Workflow{} = workflow
      assert workflow.steps[:a].timeout == 5_000
      assert workflow.steps[:b].timeout == 5_000
    end

    test "per-step options override defaults" do
      {:ok, workflow} =
        Patterns.sequential(
          [{:a, fn _r -> {:ok, 1} end, timeout: 1_000}, {:b, fn _r -> {:ok, 2} end}],
          step_defaults: [timeout: 5_000]
        )

      assert workflow.steps[:a].timeout == 1_000
      assert workflow.steps[:b].timeout == 5_000
    end

    test "bang variant returns workflow directly" do
      workflow =
        Patterns.sequential!([
          {:a, fn _r -> {:ok, 1} end},
          {:b, fn _r -> {:ok, 2} end}
        ])

      assert %Workflow{} = workflow
    end

    test "empty list returns error" do
      assert {:error, %Error{type: :workflow_error}} = Patterns.sequential([])
    end

    test "non-list returns error" do
      assert {:error, %Error{type: :workflow_error}} = Patterns.sequential(:not_a_list)
    end

    test "invalid step spec returns error" do
      assert {:error, %Error{type: :workflow_error, message: msg}} =
               Patterns.sequential(["not_a_tuple"])

      assert msg =~ "invalid step specs"
    end
  end

  describe "parallel/2" do
    test "with :from and :to — fan-out/fan-in" do
      {:ok, workflow} =
        Patterns.parallel(
          [{:b, fn r -> {:ok, elem(r[:a], 1) + 1} end},
           {:c, fn r -> {:ok, elem(r[:a], 1) + 2} end}],
          from: {:a, fn _r -> {:ok, 10} end},
          to: {:d, fn r -> {:ok, elem(r[:b], 1) + elem(r[:c], 1)} end}
        )

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 10}
      assert results[:b] == {:ok, 11}
      assert results[:c] == {:ok, 12}
      assert results[:d] == {:ok, 23}
    end

    test "without :from or :to — independent parallel steps" do
      {:ok, workflow} =
        Patterns.parallel([
          {:a, fn _r -> {:ok, 1} end},
          {:b, fn _r -> {:ok, 2} end}
        ])

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, 1}
      assert results[:b] == {:ok, 2}
    end

    test "with :from only — fan-out" do
      {:ok, workflow} =
        Patterns.parallel(
          [{:b, fn _r -> {:ok, "b"} end}, {:c, fn _r -> {:ok, "c"} end}],
          from: {:a, fn _r -> {:ok, "source"} end}
        )

      assert {:ok, results} = Executor.run(workflow)
      assert results[:a] == {:ok, "source"}
      assert results[:b] == {:ok, "b"}
      assert results[:c] == {:ok, "c"}
    end

    test "with :to only — fan-in" do
      {:ok, workflow} =
        Patterns.parallel(
          [{:a, fn _r -> {:ok, 1} end}, {:b, fn _r -> {:ok, 2} end}],
          to: {:c, fn r -> {:ok, elem(r[:a], 1) + elem(r[:b], 1)} end}
        )

      assert {:ok, results} = Executor.run(workflow)
      assert results[:c] == {:ok, 3}
    end

    test "bang variant" do
      workflow =
        Patterns.parallel!(
          [{:a, fn _r -> {:ok, 1} end}],
          from: {:src, fn _r -> {:ok, 0} end}
        )

      assert %Workflow{} = workflow
    end

    test "empty list returns error" do
      assert {:error, %Error{type: :workflow_error}} = Patterns.parallel([])
    end

    test "non-list returns error" do
      assert {:error, %Error{type: :workflow_error}} = Patterns.parallel(:bad)
    end

    test "invalid :from spec returns error" do
      assert {:error, %Error{type: :workflow_error, message: msg}} =
               Patterns.parallel(
                 [{:a, fn _r -> {:ok, 1} end}],
                 from: "not a spec"
               )

      assert msg =~ ":from"
    end
  end

  describe "conditional/3" do
    test "router with two branches — triggers matching branch" do
      {:ok, workflow} =
        Patterns.conditional(
          {:router, fn _r -> {:ok, :go_a} end},
          [
            {fn r -> r[:router] == {:ok, :go_a} end, {:branch_a, fn _r -> {:ok, "A"} end}},
            {fn r -> r[:router] == {:ok, :go_b} end, {:branch_b, fn _r -> {:ok, "B"} end}}
          ]
        )

      assert {:ok, results} = Executor.run(workflow)
      assert results[:router] == {:ok, :go_a}
      assert results[:branch_a] == {:ok, "A"}
      assert results[:branch_b] == :skipped
    end

    test "conditional with merge — merge runs when one branch fires" do
      {:ok, workflow} =
        Patterns.conditional(
          {:router, fn _r -> {:ok, :go_a} end},
          [
            {fn r -> r[:router] == {:ok, :go_a} end, {:branch_a, fn _r -> {:ok, "A"} end}},
            {fn r -> r[:router] == {:ok, :go_b} end, {:branch_b, fn _r -> {:ok, "B"} end}}
          ],
          merge: {:final, fn r ->
            a = r[:branch_a]
            b = r[:branch_b]
            {:ok, "a=#{inspect(a)}, b=#{inspect(b)}"}
          end}
        )

      assert {:ok, results} = Executor.run(workflow)
      assert results[:branch_a] == {:ok, "A"}
      assert results[:branch_b] == :skipped
      # Merge runs because branch_b is optional+skipped (not_required)
      assert {:ok, merged} = results[:final]
      assert merged =~ "A"
    end

    test "conditional with merge — branch FAILS blocks merge" do
      {:ok, workflow} =
        Patterns.conditional(
          {:router, fn _r -> {:ok, :go_both} end},
          [
            {fn _r -> true end, {:branch_a, fn _r -> {:ok, "A"} end}},
            {fn _r -> true end,
             {:branch_b, fn _r -> Error.wrap(:workflow_error, "branch_b failed") end}}
          ],
          merge: {:final, fn _r -> {:ok, "merged"} end}
        )

      assert {:ok, results} = Executor.run(workflow, on_failure: :skip)
      assert results[:branch_a] == {:ok, "A"}
      assert {:error, %Error{}} = results[:branch_b]
      # Merge is blocked because branch_b FAILED (not skipped)
      assert results[:final] == :skipped
    end

    test "conditional — all branches skipped, merge also skipped" do
      {:ok, workflow} =
        Patterns.conditional(
          {:router, fn _r -> {:ok, :none} end},
          [
            {fn r -> r[:router] == {:ok, :a} end, {:branch_a, fn _r -> {:ok, "A"} end}},
            {fn r -> r[:router] == {:ok, :b} end, {:branch_b, fn _r -> {:ok, "B"} end}}
          ],
          merge: {:final, fn _r -> {:ok, "merged"} end}
        )

      assert {:ok, results} = Executor.run(workflow)
      assert results[:branch_a] == :skipped
      assert results[:branch_b] == :skipped
      assert results[:final] == :skipped
    end

    test "bang variant" do
      workflow =
        Patterns.conditional!(
          {:router, fn _r -> {:ok, :go} end},
          [{fn _r -> true end, {:branch, fn _r -> {:ok, "yes"} end}}]
        )

      assert %Workflow{} = workflow
    end

    test "empty branches returns error" do
      assert {:error, %Error{type: :workflow_error}} =
               Patterns.conditional({:r, fn _r -> {:ok, 1} end}, [])
    end

    test "non-list branches returns error" do
      assert {:error, %Error{type: :workflow_error}} =
               Patterns.conditional({:r, fn _r -> {:ok, 1} end}, :bad)
    end

    test "invalid router spec returns error" do
      assert {:error, %Error{type: :workflow_error}} =
               Patterns.conditional(
                 "not a spec",
                 [{fn _r -> true end, {:b, fn _r -> {:ok, 1} end}}]
               )
    end

    test "invalid branch spec returns error" do
      assert {:error, %Error{type: :workflow_error, message: msg}} =
               Patterns.conditional(
                 {:r, fn _r -> {:ok, 1} end},
                 [{"not_a_fn", {:b, fn _r -> {:ok, 1} end}}]
               )

      assert msg =~ "invalid branch specs"
    end
  end

  describe "nested workflow" do
    test "branch handler wraps run_workflow" do
      inner_steps = [
        {:inner_a, fn _r -> {:ok, "inner"} end},
        {:inner_b, fn r -> {:ok, "#{elem(r[:inner_a], 1)}_done"} end}
      ]

      {:ok, workflow} =
        Patterns.sequential([
          {:outer_a, fn _r -> {:ok, "start"} end},
          {:outer_b, fn _r ->
            {:ok, inner} = Patterns.sequential(inner_steps)
            {:ok, inner_results} = Agora.run_workflow(inner)
            {:ok, elem(inner_results[:inner_b], 1)}
          end}
        ])

      assert {:ok, results} = Executor.run(workflow)
      assert results[:outer_a] == {:ok, "start"}
      assert results[:outer_b] == {:ok, "inner_done"}
    end
  end
end
