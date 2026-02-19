defmodule Agora.Tool.DateTimeTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.DateTime, as: DateTimeTool

  describe "name/0" do
    test "returns current_datetime" do
      assert DateTimeTool.name() == "current_datetime"
    end
  end

  describe "description/0" do
    test "returns a description" do
      assert is_binary(DateTimeTool.description())
    end
  end

  describe "schema/0" do
    test "returns a well-formed object schema" do
      schema = DateTimeTool.schema()
      assert schema["type"] == "object"
      assert is_map(schema["properties"])
      assert "format" in schema["required"]
    end
  end

  describe "execute/2" do
    test "date format returns YYYY-MM-DD" do
      assert {:ok, result} = DateTimeTool.execute(%{"format" => "date"}, %{})
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, result)
    end

    test "time format returns HH:MM:SS" do
      assert {:ok, result} = DateTimeTool.execute(%{"format" => "time"}, %{})
      assert Regex.match?(~r/^\d{2}:\d{2}:\d{2}$/, result)
    end

    test "datetime format returns ISO 8601" do
      assert {:ok, result} = DateTimeTool.execute(%{"format" => "datetime"}, %{})
      assert {:ok, _, _} = Elixir.DateTime.from_iso8601(result)
    end

    test "unknown format returns error" do
      assert {:error, msg} = DateTimeTool.execute(%{"format" => "epoch"}, %{})
      assert msg =~ "Unknown format"
    end
  end
end
