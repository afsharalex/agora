defmodule Agora.Memory.FileTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message, ToolCall, ToolResult}
  alias Agora.Memory.File, as: FileBackend

  defp tmp_path do
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "agora_test_#{suffix}.json")
  end

  defp cleanup(path) do
    Elixir.File.rm(path)
    Elixir.File.rm(path <> ".tmp.*")
  end

  describe "init/1" do
    test "new file (enoent) starts empty" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      assert {:ok, state} = FileBackend.init(path: path)
      assert state.path == path
    end

    test "existing valid file loads successfully" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      # Write a valid JSON array
      content =
        Jason.encode!([
          %{
            "role" => "user",
            "content" => "hello",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:ok, state} = FileBackend.init(path: path)
      assert state.path == path
    end

    test "corrupt JSON file returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      Elixir.File.write!(path, "not json at all{{{")

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "JSON decode failed"
    end

    test "non-array JSON returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      Elixir.File.write!(path, ~s({"key": "value"}))

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected JSON array"
    end

    test "missing :path returns error" do
      assert {:error, %Error{type: :memory_error, message: message}} = FileBackend.init([])
      assert message =~ ":path is required"
    end

    test "non-string :path returns error" do
      assert {:error, %Error{type: :memory_error}} = FileBackend.init(path: 123)
    end
  end

  describe "save/2 and get/1" do
    test "writes to file and data round-trips" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      messages = [Message.user("hello"), Message.assistant("hi")]

      {:ok, state} = FileBackend.save(state, messages)
      {:ok, retrieved} = FileBackend.get(state)

      assert length(retrieved) == 2
      assert Enum.at(retrieved, 0).role == :user
      assert Enum.at(retrieved, 0).content == "hello"
      assert Enum.at(retrieved, 1).role == :assistant
      assert Enum.at(retrieved, 1).content == "hi"
    end

    test "messages with tool_calls survive round-trip" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)

      tc =
        ToolCall.new(%{
          id: "call_1",
          name: "search",
          arguments: %{"q" => "elixir"},
          status: :completed
        })

      msg = Message.assistant(nil, [tc])

      {:ok, state} = FileBackend.save(state, [msg])
      {:ok, [retrieved]} = FileBackend.get(state)

      assert retrieved.role == :assistant
      assert retrieved.content == nil
      assert length(retrieved.tool_calls) == 1

      rtc = hd(retrieved.tool_calls)
      assert rtc.id == "call_1"
      assert rtc.name == "search"
      assert rtc.arguments == %{"q" => "elixir"}
      assert rtc.status == :completed
    end

    test "messages with tool_results survive round-trip" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)

      tr = %ToolResult{
        tool_call_id: "call_1",
        name: "search",
        content: "found 3 results",
        is_error: false
      }

      msg = Message.new(:tool, nil, tool_results: [tr])

      {:ok, state} = FileBackend.save(state, [msg])
      {:ok, [retrieved]} = FileBackend.get(state)

      assert retrieved.role == :tool
      assert length(retrieved.tool_results) == 1

      rtr = hd(retrieved.tool_results)
      assert rtr.tool_call_id == "call_1"
      assert rtr.name == "search"
      assert rtr.content == "found 3 results"
      assert rtr.is_error == false
    end

    test "DateTime preserved through round-trip" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      msg = Message.user("timestamped")

      {:ok, state} = FileBackend.save(state, [msg])
      {:ok, [retrieved]} = FileBackend.get(state)

      assert %DateTime{} = retrieved.created_at
      assert DateTime.diff(msg.created_at, retrieved.created_at, :second) == 0
    end

    test "empty list clears file contents" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, [Message.user("hello")])
      {:ok, state} = FileBackend.save(state, [])

      {:ok, retrieved} = FileBackend.get(state)
      assert retrieved == []
    end

    test "unwritable path returns typed error" do
      path = "/nonexistent_root_dir_12345/impossible/file.json"

      {:ok, state} = FileBackend.init(path: path)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.save(state, [Message.user("hello")])

      assert message =~ "Failed to write"
    end
  end

  describe "get/1" do
    test "returns empty list for missing file" do
      path = tmp_path()
      {:ok, state} = FileBackend.init(path: path)
      assert {:ok, []} = FileBackend.get(state)
    end

    test "reads from disk (no cache)" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, [Message.user("v1")])

      # Overwrite file directly to verify no caching
      content =
        Jason.encode!([
          %{
            "role" => "user",
            "content" => "v2",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      {:ok, [msg]} = FileBackend.get(state)
      assert msg.content == "v2"
    end
  end

  describe "clear/1" do
    test "removes file" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, [Message.user("hello")])
      assert Elixir.File.exists?(path)

      {:ok, _state} = FileBackend.clear(state)
      refute Elixir.File.exists?(path)
    end

    test "subsequent get returns empty after clear" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, [Message.user("hello")])
      {:ok, state} = FileBackend.clear(state)

      assert {:ok, []} = FileBackend.get(state)
    end

    test "clear on non-existent file succeeds" do
      path = tmp_path()
      {:ok, state} = FileBackend.init(path: path)
      assert {:ok, _state} = FileBackend.clear(state)
    end
  end

  describe "serialization edge cases" do
    test "nil content preserved" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      msg = Message.assistant(nil)

      {:ok, state} = FileBackend.save(state, [msg])
      {:ok, [retrieved]} = FileBackend.get(state)

      assert retrieved.content == nil
    end

    test "empty tool_calls list preserved" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      msg = Message.user("hello")

      {:ok, state} = FileBackend.save(state, [msg])
      {:ok, [retrieved]} = FileBackend.get(state)

      assert retrieved.tool_calls == []
    end

    test "metadata maps preserved" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)
      msg = Message.new(:user, "hello", metadata: %{"key" => "value", "nested" => %{"a" => 1}})

      {:ok, state} = FileBackend.save(state, [msg])
      {:ok, [retrieved]} = FileBackend.get(state)

      assert retrieved.metadata == %{"key" => "value", "nested" => %{"a" => 1}}
    end

    test "unknown role in JSON returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "alien",
            "content" => "hello",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      # init reads and validates, detecting the invalid role
      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Unknown message role"
    end

    test "non-string role returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => 123,
            "content" => "hello",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Invalid message role type"
    end

    test "non-string created_at returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "user",
            "content" => "hello",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => 123
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Invalid datetime type"
    end

    test "non-array tool_calls returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => "not_an_array",
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected tool_calls to be an array"
    end

    test "non-array tool_results returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "tool",
            "content" => nil,
            "tool_calls" => [],
            "tool_results" => "not_an_array",
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected tool_results to be an array"
    end

    test "non-map tool_call entry returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => ["not_a_map"],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected tool_call to be a JSON object"
    end

    test "non-string tool_call status returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{"id" => "c1", "name" => "test", "arguments" => %{}, "status" => 42}
            ],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Invalid tool call status type"
    end

    test "error tool result round-trips" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      {:ok, state} = FileBackend.init(path: path)

      tr = %ToolResult{tool_call_id: "c1", name: "search", content: "timeout", is_error: true}
      msg = Message.new(:tool, nil, tool_results: [tr])

      {:ok, state} = FileBackend.save(state, [msg])
      {:ok, [retrieved]} = FileBackend.get(state)

      rtr = hd(retrieved.tool_results)
      assert rtr.is_error == true
      assert rtr.content == "timeout"
    end

    test "non-map metadata returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "user",
            "content" => "hello",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => "not_a_map",
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected metadata to be a map"
    end

    test "non-string tool_call id returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{"id" => 123, "name" => "test", "arguments" => %{}, "status" => "pending"}
            ],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected tool_call.id to be a string"
    end

    test "non-map tool_call arguments returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{"id" => "c1", "name" => "test", "arguments" => "bad", "status" => "pending"}
            ],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected tool_call.arguments to be a map"
    end

    test "non-boolean tool_result is_error returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "tool",
            "content" => nil,
            "tool_calls" => [],
            "tool_results" => [
              %{
                "tool_call_id" => "c1",
                "name" => "test",
                "content" => "result",
                "is_error" => "yes"
              }
            ],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected tool_result.is_error to be a boolean"
    end

    test "non-string tool_result name returns error" do
      path = tmp_path()
      on_exit(fn -> cleanup(path) end)

      content =
        Jason.encode!([
          %{
            "role" => "tool",
            "content" => nil,
            "tool_calls" => [],
            "tool_results" => [
              %{"tool_call_id" => "c1", "name" => 42, "content" => "result", "is_error" => false}
            ],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      Elixir.File.write!(path, content)

      assert {:error, %Error{type: :memory_error, message: message}} =
               FileBackend.init(path: path)

      assert message =~ "Expected tool_result.name to be a string"
    end
  end
end
