defmodule Agora.Workflow.EdgeTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.Edge

  describe "new/1" do
    test "creates edge with from and to" do
      assert {:ok, edge} = Edge.new(from: :a, to: :b)
      assert edge.from == :a
      assert edge.to == :b
      assert edge.condition == nil
    end

    test "creates edge with condition function" do
      condition = fn _results -> true end
      assert {:ok, edge} = Edge.new(from: :a, to: :b, condition: condition)
      assert edge.condition == condition
    end

    test "returns error when from is missing" do
      assert {:error, error} = Edge.new(to: :b)
      assert error.type == :workflow_error
      assert error.message =~ ":from is required"
    end

    test "returns error when to is missing" do
      assert {:error, error} = Edge.new(from: :a)
      assert error.type == :workflow_error
      assert error.message =~ ":to is required"
    end

    test "returns error on self-loop" do
      assert {:error, error} = Edge.new(from: :a, to: :a)
      assert error.type == :workflow_error
      assert error.message =~ "self-loop"
    end

    test "returns error when from is not an atom" do
      assert {:error, error} = Edge.new(from: "string", to: :b)
      assert error.type == :workflow_error
      assert error.message =~ ":from must be an atom"
    end

    test "returns error when to is not an atom" do
      assert {:error, error} = Edge.new(from: :a, to: 123)
      assert error.type == :workflow_error
      assert error.message =~ ":to must be an atom"
    end

    test "returns error when condition is not a 1-arity function" do
      assert {:error, error} = Edge.new(from: :a, to: :b, condition: "not_a_fn")
      assert error.type == :workflow_error
      assert error.message =~ ":condition must be a 1-arity function"
    end

    test "creates edge with optional: true" do
      assert {:ok, edge} = Edge.new(from: :a, to: :b, optional: true)
      assert edge.optional == true
    end

    test "creates edge with optional: false" do
      assert {:ok, edge} = Edge.new(from: :a, to: :b, optional: false)
      assert edge.optional == false
    end

    test "defaults optional to false" do
      assert {:ok, edge} = Edge.new(from: :a, to: :b)
      assert edge.optional == false
    end

    test "returns error when optional is not a boolean" do
      assert {:error, error} = Edge.new(from: :a, to: :b, optional: "yes")
      assert error.type == :workflow_error
      assert error.message =~ ":optional must be a boolean"
    end
  end

  describe "new!/1" do
    test "returns edge on valid input" do
      edge = Edge.new!(from: :a, to: :b)
      assert edge.from == :a
      assert edge.to == :b
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn ->
        Edge.new!(from: :a, to: :a)
      end
    end
  end
end
