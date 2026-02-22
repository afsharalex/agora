defmodule Agora.Tool.ThinkTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.Think

  describe "name/0" do
    test "returns think" do
      assert Think.name() == "think"
    end
  end

  describe "schema/0" do
    test "requires thought parameter" do
      schema = Think.schema()
      assert schema["required"] == ["thought"]
      assert schema["properties"]["thought"]["type"] == "string"
    end
  end

  describe "execute/2" do
    test "returns the thought unchanged" do
      thought = "Let me think step by step about this problem..."
      assert {:ok, ^thought} = Think.execute(%{"thought" => thought}, %{})
    end

    test "handles multiline thoughts" do
      thought = "Step 1: Analyze\nStep 2: Plan\nStep 3: Execute"
      assert {:ok, ^thought} = Think.execute(%{"thought" => thought}, %{})
    end
  end
end
