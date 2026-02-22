defmodule Agora.Tool.JsonTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.Json

  describe "name/0" do
    test "returns json" do
      assert Json.name() == "json"
    end
  end

  describe "execute/2 - parse" do
    test "parses valid JSON object" do
      assert {:ok, %{"name" => "Alice", "age" => 30}} =
               Json.execute(
                 %{"operation" => "parse", "input" => ~s({"name":"Alice","age":30})},
                 %{}
               )
    end

    test "parses valid JSON array" do
      assert {:ok, [1, 2, 3]} =
               Json.execute(%{"operation" => "parse", "input" => "[1,2,3]"}, %{})
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} =
               Json.execute(%{"operation" => "parse", "input" => "not json"}, %{})

      assert msg =~ "Invalid JSON"
    end
  end

  describe "execute/2 - format" do
    test "pretty-prints JSON" do
      assert {:ok, formatted} =
               Json.execute(
                 %{"operation" => "format", "input" => ~s({"a":1,"b":2})},
                 %{}
               )

      assert formatted =~ "\n"
      assert Jason.decode!(formatted) == %{"a" => 1, "b" => 2}
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} =
               Json.execute(%{"operation" => "format", "input" => "{bad"}, %{})

      assert msg =~ "Invalid JSON"
    end
  end

  describe "execute/2 - query" do
    test "queries simple key" do
      input = ~s({"name":"Alice","age":30})

      assert {:ok, "Alice"} =
               Json.execute(
                 %{"operation" => "query", "input" => input, "path" => "name"},
                 %{}
               )
    end

    test "queries nested path" do
      input = ~s({"data":{"items":[{"name":"first"},{"name":"second"}]}})

      assert {:ok, "first"} =
               Json.execute(
                 %{"operation" => "query", "input" => input, "path" => "data.items[0].name"},
                 %{}
               )
    end

    test "queries array index" do
      input = ~s([10,20,30])

      assert {:ok, 20} =
               Json.execute(
                 %{"operation" => "query", "input" => input, "path" => "[1]"},
                 %{}
               )
    end

    test "returns error for missing key" do
      assert {:error, msg} =
               Json.execute(
                 %{"operation" => "query", "input" => ~s({"a":1}), "path" => "b"},
                 %{}
               )

      assert msg =~ "not found"
    end

    test "returns error for out-of-bounds index" do
      assert {:error, msg} =
               Json.execute(
                 %{"operation" => "query", "input" => "[1,2]", "path" => "[5]"},
                 %{}
               )

      assert msg =~ "out of bounds"
    end

    test "returns error when path is missing" do
      assert {:error, msg} =
               Json.execute(
                 %{"operation" => "query", "input" => ~s({"a":1})},
                 %{}
               )

      assert msg =~ "path"
    end

    test "returns error for invalid JSON in query" do
      assert {:error, msg} =
               Json.execute(
                 %{"operation" => "query", "input" => "bad", "path" => "a"},
                 %{}
               )

      assert msg =~ "Invalid JSON"
    end
  end
end
