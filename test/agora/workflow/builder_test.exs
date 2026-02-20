defmodule Agora.Workflow.BuilderTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.Builder

  defp handler(_results), do: {:ok, "done"}

  describe "step/3" do
    test "adds a step to the builder" do
      builder = Builder.new() |> Builder.step(:fetch, &handler/1)
      assert Map.has_key?(builder.steps, :fetch)
      assert builder.steps[:fetch].id == :fetch
    end

    test "adds step with options" do
      builder =
        Builder.new()
        |> Builder.step(:fetch, &handler/1,
          name: "Fetch Data",
          inputs: [:source],
          timeout: 5_000,
          retry: 2
        )

      step = builder.steps[:fetch]
      assert step.name == "Fetch Data"
      assert step.inputs == [:source]
      assert step.timeout == 5_000
      assert step.retry == 2
    end
  end

  describe "edge/3" do
    test "adds an edge to the builder" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.edge(:a, :b)

      assert length(builder.edges) == 1
      [edge] = builder.edges
      assert edge.from == :a
      assert edge.to == :b
    end

    test "adds edge with condition" do
      condition = fn _results -> true end

      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.edge(:a, :b, condition: condition)

      [edge] = builder.edges
      assert edge.condition == condition
    end
  end

  describe "sequence/2" do
    test "chains step IDs into linear edges" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.step(:c, &handler/1)
        |> Builder.sequence([:a, :b, :c])

      assert length(builder.edges) == 2
      [e1, e2] = builder.edges
      assert {e1.from, e1.to} == {:a, :b}
      assert {e2.from, e2.to} == {:b, :c}
    end

    test "handles empty and single-element lists" do
      builder = Builder.new()
      assert Builder.sequence(builder, []).edges == []
      assert Builder.sequence(builder, [:a]).edges == []
    end
  end

  describe "parallel/2" do
    test "creates fan-out edges with :from" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.step(:c, &handler/1)
        |> Builder.parallel([:b, :c], from: :a)

      assert length(builder.edges) == 2
      froms = Enum.map(builder.edges, & &1.from)
      tos = Enum.map(builder.edges, & &1.to)
      assert Enum.all?(froms, &(&1 == :a))
      assert :b in tos
      assert :c in tos
    end

    test "creates fan-in edges with :to" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.step(:c, &handler/1)
        |> Builder.parallel([:a, :b], to: :c)

      assert length(builder.edges) == 2
      tos = Enum.map(builder.edges, & &1.to)
      froms = Enum.map(builder.edges, & &1.from)
      assert Enum.all?(tos, &(&1 == :c))
      assert :a in froms
      assert :b in froms
    end

    test "creates both fan-out and fan-in with :from and :to" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.step(:c, &handler/1)
        |> Builder.step(:d, &handler/1)
        |> Builder.parallel([:b, :c], from: :a, to: :d)

      assert length(builder.edges) == 4
    end
  end

  describe "build/1" do
    test "builds valid linear workflow" do
      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.step(:c, &handler/1)
               |> Builder.sequence([:a, :b, :c])
               |> Builder.build()

      assert map_size(workflow.steps) == 3
      assert length(workflow.edges) == 2
    end

    test "builds valid parallel workflow" do
      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.step(:c, &handler/1)
               |> Builder.step(:d, &handler/1)
               |> Builder.parallel([:b, :c], from: :a, to: :d)
               |> Builder.build()

      assert map_size(workflow.steps) == 4
    end

    test "auto-generates edges from step inputs" do
      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1, inputs: [:a])
               |> Builder.build()

      assert length(workflow.edges) == 1
      [edge] = workflow.edges
      assert edge.from == :a
      assert edge.to == :b
    end

    test "explicit edge takes precedence over auto-generated" do
      condition = fn _r -> true end

      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1, inputs: [:a])
               |> Builder.edge(:a, :b, condition: condition)
               |> Builder.build()

      # Should have only 1 edge (explicit, not duplicated)
      assert length(workflow.edges) == 1
      [edge] = workflow.edges
      assert edge.condition == condition
    end

    test "returns error for unknown step in edge" do
      assert {:error, error} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.edge(:a, :unknown)
               |> Builder.build()

      assert error.type == :workflow_error
      assert error.message =~ "unknown step IDs"
    end

    test "returns error for unknown step in inputs" do
      assert {:error, error} =
               Builder.new()
               |> Builder.step(:a, &handler/1, inputs: [:nonexistent])
               |> Builder.build()

      assert error.type == :workflow_error
      assert error.message =~ "unknown step IDs"
    end

    test "returns error for cycle A -> B -> C -> A" do
      assert {:error, error} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.step(:c, &handler/1)
               |> Builder.edge(:a, :b)
               |> Builder.edge(:b, :c)
               |> Builder.edge(:c, :a)
               |> Builder.build()

      assert error.type == :workflow_error
      assert error.message =~ "cycle"
    end

    test "builds single-step workflow" do
      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:only, &handler/1)
               |> Builder.build()

      assert map_size(workflow.steps) == 1
      assert workflow.edges == []
    end

    test "builds disconnected steps (no edges)" do
      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.build()

      assert map_size(workflow.steps) == 2
      assert workflow.edges == []
    end
  end

  describe "build!/1" do
    test "returns workflow on valid input" do
      workflow =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.build!()

      assert workflow.steps[:a].id == :a
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn ->
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.edge(:a, :b)
        |> Builder.build!()
      end
    end
  end

  describe "non-bang helpers never raise" do
    test "step/3 with invalid handler accumulates error" do
      builder =
        Builder.new()
        |> Builder.step(:bad, "not_a_function")

      assert {:error, error} = Builder.build(builder)
      assert error.type == :workflow_error
      assert error.message =~ "Builder errors"
    end

    test "edge/3 with self-loop accumulates error" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.edge(:a, :a)

      assert {:error, error} = Builder.build(builder)
      assert error.type == :workflow_error
      assert error.message =~ "Builder errors"
    end
  end

  describe "parallel/3 validation" do
    test "returns error when neither :from nor :to provided" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.parallel([:a, :b], [])

      assert {:error, error} = Builder.build(builder)
      assert error.type == :workflow_error
      assert error.message =~ "at least one of :from or :to"
    end
  end

  describe "duplicate step detection" do
    test "duplicate step ID via step/4 produces error" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1, name: "first")
        |> Builder.step(:a, &handler/1, name: "second")

      assert {:error, error} = Builder.build(builder)
      assert error.type == :workflow_error
      assert error.message =~ "already exists"
      # Original step preserved, not overwritten
      assert builder.steps[:a].name == "first"
    end

    test "non-duplicate steps work as before" do
      assert {:ok, _workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1, [])
               |> Builder.step(:b, &handler/1, [])
               |> Builder.build()
    end
  end

  describe "duplicate edge detection" do
    test "duplicate edge via edge/4 produces error" do
      assert {:error, error} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.edge(:a, :b)
               |> Builder.edge(:a, :b)
               |> Builder.build()

      assert error.type == :workflow_error
      assert error.message =~ "already exists"
    end

    test "duplicate edge via sequence/2 produces error" do
      assert {:error, error} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.step(:c, &handler/1)
               |> Builder.sequence([:a, :b, :c])
               |> Builder.sequence([:a, :b])
               |> Builder.build()

      assert error.type == :workflow_error
      assert error.message =~ "already exists"
    end

    test "duplicate edge via parallel/3 produces error" do
      assert {:error, error} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.step(:c, &handler/1)
               |> Builder.parallel([:b, :c], from: :a)
               |> Builder.parallel([:b, :c], from: :a)
               |> Builder.build()

      assert error.type == :workflow_error
      assert error.message =~ "already exists"
    end

    test "duplicate {from, to} with different conditions produces error" do
      assert {:error, error} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1)
               |> Builder.edge(:a, :b, condition: fn _ -> true end)
               |> Builder.edge(:a, :b)
               |> Builder.build()

      assert error.type == :workflow_error
      assert error.message =~ "already exists"
    end
  end

  describe "step_defaults" do
    test "new/1 stores step_defaults on struct" do
      builder = Builder.new(step_defaults: [timeout: 30_000])
      assert builder.step_defaults == [timeout: 30_000]
    end

    test "per-step opts override defaults" do
      builder =
        Builder.new(step_defaults: [timeout: 30_000])
        |> Builder.step(:a, &handler/1, timeout: 5_000)

      assert builder.steps[:a].timeout == 5_000
    end

    test "new/0 still works with empty defaults" do
      builder = Builder.new()
      assert builder.step_defaults == []
    end

    test "non-allowed keys produce error" do
      builder = Builder.new(step_defaults: [name: "x"])
      assert {:error, error} = Builder.build(builder)
      assert error.message =~ "only accepts :timeout and :retry"
    end

    test "wiring keys produce error" do
      builder = Builder.new(step_defaults: [after: :a])
      assert {:error, error} = Builder.build(builder)
      assert error.message =~ "only accepts :timeout and :retry"
    end

    test "non-keyword step_defaults produces error" do
      builder = Builder.new(step_defaults: :bad)
      assert {:error, error} = Builder.build(builder)
      assert error.message =~ "keyword list"
    end

    test "non-keyword new/1 arg produces error" do
      builder = Builder.new(:bad)
      assert {:error, error} = Builder.build(builder)
      assert error.message =~ "keyword list"
    end

    test "defaults applied when step has no overrides" do
      builder =
        Builder.new(step_defaults: [timeout: 10_000, retry: 3])
        |> Builder.step(:a, &handler/1)

      assert builder.steps[:a].timeout == 10_000
      assert builder.steps[:a].retry == 3
    end
  end

  describe "after: alias" do
    test "after: atom normalizes to inputs: [atom]" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1, after: :a)

      assert builder.steps[:b].inputs == [:a]
    end

    test "after: list normalizes to inputs: list" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1)
        |> Builder.step(:c, &handler/1, after: [:a, :b])

      assert builder.steps[:c].inputs == [:a, :b]
    end

    test "after: and inputs: together produces error" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1)
        |> Builder.step(:b, &handler/1, after: :a, inputs: [:a])

      assert {:error, error} = Builder.build(builder)
      assert error.message =~ "both :after and :inputs"
    end

    test "auto-edge generation works with after:" do
      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1, after: :a)
               |> Builder.build()

      assert length(workflow.edges) == 1
      [edge] = workflow.edges
      assert edge.from == :a
      assert edge.to == :b
    end

    test "inputs: continues to work unchanged" do
      assert {:ok, workflow} =
               Builder.new()
               |> Builder.step(:a, &handler/1)
               |> Builder.step(:b, &handler/1, inputs: [:a])
               |> Builder.build()

      assert length(workflow.edges) == 1
      [edge] = workflow.edges
      assert edge.from == :a
      assert edge.to == :b
    end
  end

  describe ":input reserved ID" do
    test "step with id :input is rejected at build" do
      builder =
        Builder.new()
        |> Builder.step(:input, &handler/1)

      assert {:error, error} = Builder.build(builder)
      assert error.message =~ "reserved"
    end
  end

  describe "auto-edge errors surfaced at build" do
    test "self-loop via inputs is caught" do
      builder =
        Builder.new()
        |> Builder.step(:a, &handler/1, inputs: [:a])

      assert {:error, error} = Builder.build(builder)
      assert error.type == :workflow_error
      assert error.message =~ "self-loop" or error.message =~ "Builder errors"
    end
  end
end
