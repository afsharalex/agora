defmodule Agora.Workflow.StepTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.Step
  alias Agora.AgentConfig

  describe "new/1" do
    test "creates step with function handler" do
      handler = fn _results -> {:ok, "done"} end
      assert {:ok, step} = Step.new(id: :fetch, handler: handler)
      assert step.id == :fetch
      assert step.handler == handler
      assert step.name == "fetch"
      assert step.inputs == []
      assert step.outputs == nil
      assert step.input_mapper == nil
      assert step.timeout == 300_000
      assert step.retry == 0
    end

    test "creates step with AgentConfig handler" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      assert {:ok, step} = Step.new(id: :agent_step, handler: config)
      assert step.handler == config
    end

    test "creates step with inputs list" do
      handler = fn _r -> {:ok, "done"} end
      assert {:ok, step} = Step.new(id: :transform, handler: handler, inputs: [:fetch, :validate])
      assert step.inputs == [:fetch, :validate]
    end

    test "creates step with input_mapper" do
      handler = fn _r -> {:ok, "done"} end
      mapper = fn results -> "Input: #{inspect(results)}" end

      assert {:ok, step} = Step.new(id: :step, handler: handler, input_mapper: mapper)
      assert is_function(step.input_mapper, 1)
    end

    test "creates step with outputs schema" do
      handler = fn _r -> {:ok, 42} end
      outputs = %{value: :integer}

      assert {:ok, step} = Step.new(id: :step, handler: handler, outputs: outputs)
      assert step.outputs == %{value: :integer}
    end

    test "creates step with custom name" do
      handler = fn _r -> {:ok, "done"} end
      assert {:ok, step} = Step.new(id: :my_step, handler: handler, name: "My Step")
      assert step.name == "My Step"
    end

    test "creates step with custom timeout and retry" do
      handler = fn _r -> {:ok, "done"} end
      assert {:ok, step} = Step.new(id: :step, handler: handler, timeout: 5_000, retry: 3)
      assert step.timeout == 5_000
      assert step.retry == 3
    end

    test "returns error when id is missing" do
      handler = fn _r -> {:ok, "done"} end
      assert {:error, error} = Step.new(handler: handler)
      assert error.type == :workflow_error
      assert error.message =~ ":id is required"
    end

    test "returns error when id is not an atom" do
      handler = fn _r -> {:ok, "done"} end
      assert {:error, error} = Step.new(id: "string", handler: handler)
      assert error.type == :workflow_error
      assert error.message =~ ":id must be an atom"
    end

    test "returns error when handler is missing" do
      assert {:error, error} = Step.new(id: :step)
      assert error.type == :workflow_error
      assert error.message =~ ":handler is required"
    end

    test "returns error when handler is invalid" do
      assert {:error, error} = Step.new(id: :step, handler: "not_a_function")
      assert error.type == :workflow_error
      assert error.message =~ ":handler must be"
    end

    test "returns error when handler is wrong arity" do
      assert {:error, error} = Step.new(id: :step, handler: fn a, b -> {a, b} end)
      assert error.type == :workflow_error
    end

    test "returns error when inputs is not a list of atoms" do
      handler = fn _r -> {:ok, "done"} end
      assert {:error, error} = Step.new(id: :step, handler: handler, inputs: ["string"])
      assert error.type == :workflow_error
      assert error.message =~ ":inputs must be a list of atoms"
    end

    test "returns error when timeout is invalid" do
      handler = fn _r -> {:ok, "done"} end
      assert {:error, error} = Step.new(id: :step, handler: handler, timeout: -1)
      assert error.type == :workflow_error
      assert error.message =~ ":timeout must be a positive integer"
    end

    test "returns error when retry is negative" do
      handler = fn _r -> {:ok, "done"} end
      assert {:error, error} = Step.new(id: :step, handler: handler, retry: -1)
      assert error.type == :workflow_error
      assert error.message =~ ":retry must be a non-negative integer"
    end

    test "returns error for reserved id :input" do
      handler = fn _r -> {:ok, "done"} end
      assert {:error, error} = Step.new(id: :input, handler: handler)
      assert error.type == :workflow_error
      assert error.message =~ "reserved"
    end
  end

  describe "new!/1" do
    test "returns step on valid input" do
      handler = fn _r -> {:ok, "done"} end
      step = Step.new!(id: :step, handler: handler)
      assert step.id == :step
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn ->
        Step.new!(id: "not_atom", handler: fn _r -> :ok end)
      end
    end
  end
end
