defmodule Agora.Tool.RegexTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.Regex, as: RegexTool

  describe "name/0" do
    test "returns regex" do
      assert RegexTool.name() == "regex"
    end
  end

  describe "execute/2 - match" do
    test "returns match when pattern matches" do
      assert {:ok, ["hello"]} =
               RegexTool.execute(
                 %{"operation" => "match", "pattern" => "hello", "input" => "say hello world"},
                 %{}
               )
    end

    test "returns capture groups" do
      assert {:ok, ["hello world", "world"]} =
               RegexTool.execute(
                 %{
                   "operation" => "match",
                   "pattern" => "hello (\\w+)",
                   "input" => "say hello world"
                 },
                 %{}
               )
    end

    test "returns nil when no match" do
      assert {:ok, nil} =
               RegexTool.execute(
                 %{"operation" => "match", "pattern" => "xyz", "input" => "hello"},
                 %{}
               )
    end
  end

  describe "execute/2 - scan" do
    test "finds all matches" do
      assert {:ok, [["cat"], ["bat"], ["hat"]]} =
               RegexTool.execute(
                 %{"operation" => "scan", "pattern" => "[a-z]at", "input" => "cat bat hat"},
                 %{}
               )
    end

    test "returns empty list when no matches" do
      assert {:ok, []} =
               RegexTool.execute(
                 %{"operation" => "scan", "pattern" => "\\d+", "input" => "no numbers here"},
                 %{}
               )
    end
  end

  describe "execute/2 - replace" do
    test "replaces all matches" do
      assert {:ok, "h-ll- w-rld"} =
               RegexTool.execute(
                 %{
                   "operation" => "replace",
                   "pattern" => "[aeiou]",
                   "input" => "hello world",
                   "replacement" => "-"
                 },
                 %{}
               )
    end

    test "returns error when replacement is missing" do
      assert {:error, msg} =
               RegexTool.execute(
                 %{"operation" => "replace", "pattern" => "a", "input" => "abc"},
                 %{}
               )

      assert msg =~ "replacement"
    end
  end

  describe "execute/2 - invalid regex" do
    test "returns error for invalid pattern" do
      assert {:error, msg} =
               RegexTool.execute(
                 %{"operation" => "match", "pattern" => "[invalid", "input" => "test"},
                 %{}
               )

      assert msg =~ "Invalid regex"
    end
  end
end
