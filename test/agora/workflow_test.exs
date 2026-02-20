defmodule Agora.WorkflowTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow

  describe "struct" do
    test "has default values" do
      workflow = %Workflow{}
      assert workflow.steps == %{}
      assert workflow.edges == []
      assert workflow.metadata == %{}
    end
  end
end
