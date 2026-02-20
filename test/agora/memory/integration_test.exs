defmodule Agora.Memory.FailingSaveBackend do
  @moduledoc false
  @behaviour Agora.Memory

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def get(_state), do: {:ok, []}

  @impl true
  def save(_state, _messages),
    do: {:error, Agora.Error.new(:memory_error, "Simulated save failure")}

  @impl true
  def clear(state), do: {:ok, state}
end

defmodule Agora.Memory.IntegrationTest do
  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig, Error, Message}

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  defp tmp_path do
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "agora_integration_#{suffix}.json")
  end

  describe "Buffer: basic operations" do
    test "run stores messages in memory" do
      config = echo_config(memory: {Agora.Memory.Buffer, max_messages: 100})
      {:ok, pid} = Agent.start_link(config: config)

      {:ok, _resp} = Agent.run(pid, "Hello!")
      messages = Agent.get_messages(pid)

      # system message was not set, so: [user, assistant]
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :assistant
    end

    test "multiple runs accumulate messages" do
      config =
        echo_config(
          instructions: "You are helpful.",
          memory: {Agora.Memory.Buffer, max_messages: 100}
        )

      {:ok, pid} = Agent.start_link(config: config)

      {:ok, _} = Agent.run(pid, "First")
      {:ok, _} = Agent.run(pid, "Second")

      messages = Agent.get_messages(pid)
      # system + user1 + asst1 + user2 + asst2
      assert length(messages) == 5
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end

    test "ring buffer bounds context" do
      config =
        echo_config(
          instructions: "System prompt.",
          memory: {Agora.Memory.Buffer, max_messages: 4}
        )

      {:ok, pid} = Agent.start_link(config: config)

      # Each run adds 2 messages (user + assistant), buffer max is 4
      {:ok, _} = Agent.run(pid, "msg 1")
      {:ok, _} = Agent.run(pid, "msg 2")
      {:ok, _} = Agent.run(pid, "msg 3")

      messages = Agent.get_messages(pid)
      # system + last 4 non-system messages (user2, asst2, user3, asst3)
      assert length(messages) == 5

      non_system = Enum.reject(messages, &(&1.role == :system))
      assert length(non_system) == 4

      # First message's content should be gone
      user_contents = non_system |> Enum.filter(&(&1.role == :user)) |> Enum.map(& &1.content)
      refute "msg 1" in user_contents
    end

    test "system message always present, never stored in memory" do
      config =
        echo_config(
          instructions: "Always here.",
          memory: {Agora.Memory.Buffer, max_messages: 2}
        )

      {:ok, pid} = Agent.start_link(config: config)

      {:ok, _} = Agent.run(pid, "First")
      {:ok, _} = Agent.run(pid, "Second")
      {:ok, _} = Agent.run(pid, "Third")

      messages = Agent.get_messages(pid)
      system_msgs = Enum.filter(messages, &(&1.role == :system))
      assert length(system_msgs) == 1
      assert hd(system_msgs).content == "Always here."
    end
  end

  describe "File: system message filtering on reload" do
    test "persisted system messages are filtered out on load" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      # Manually write a file with a system message to simulate corrupt/old data
      content =
        Jason.encode!([
          %{
            "role" => "system",
            "content" => "Stale system prompt",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          },
          %{
            "role" => "user",
            "content" => "hello",
            "tool_calls" => [],
            "tool_results" => [],
            "metadata" => %{},
            "created_at" => nil
          }
        ])

      File.write!(path, content)

      config =
        echo_config(
          instructions: "Current system prompt.",
          memory: {Agora.Memory.File, path: path}
        )

      {:ok, pid} = Agent.start_link(config: config)
      messages = Agent.get_messages(pid)

      system_msgs = Enum.filter(messages, &(&1.role == :system))
      assert length(system_msgs) == 1
      assert hd(system_msgs).content == "Current system prompt."

      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 1
      assert hd(user_msgs).content == "hello"
    end
  end

  describe "File: persistence across restarts" do
    test "messages persist across agent restarts" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      config =
        echo_config(
          instructions: "Persistent.",
          memory: {Agora.Memory.File, path: path}
        )

      # First agent instance
      {:ok, pid1} = Agent.start_link(config: config)
      {:ok, _} = Agent.run(pid1, "Remember me")
      GenServer.stop(pid1)

      # Second agent instance — same file path
      {:ok, pid2} = Agent.start_link(config: config)
      messages = Agent.get_messages(pid2)

      # system + persisted user + persisted assistant
      assert length(messages) == 3
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert hd(user_msgs).content == "Remember me"
    end

    test "tool call messages round-trip through file" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      add_tool =
        Agora.Tool.FunctionTool.new!(
          name: "add",
          description: "Adds",
          schema: %{"type" => "object", "properties" => %{}},
          function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, a + b} end
        )

      call_count = :counters.new(1, [:atomics])

      config =
        echo_config(
          tools: [add_tool],
          memory: {Agora.Memory.File, path: path},
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)

              if count == 1 do
                call =
                  Agora.ToolCall.new(%{id: "c1", name: "add", arguments: %{"a" => 1, "b" => 2}})

                {:ok, Message.assistant(nil, [call])}
              else
                {:ok, Message.assistant("Done")}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, _} = Agent.run(pid, "Add numbers")
      GenServer.stop(pid)

      # Restart with fresh counter
      call_count2 = :counters.new(1, [:atomics])

      config2 =
        echo_config(
          tools: [add_tool],
          memory: {Agora.Memory.File, path: path},
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              :counters.add(call_count2, 1, 1)
              # Verify tool history is present
              tool_msgs = Enum.filter(messages, &(&1.role == :tool))
              {:ok, Message.assistant("Has #{length(tool_msgs)} tool messages")}
            end
          ]
        )

      {:ok, pid2} = Agent.start_link(config: config2)
      {:ok, resp} = Agent.run(pid2, "Check history")

      assert resp.content == "Has 1 tool messages"
    end
  end

  describe "clear_memory/1" do
    test "clears and resets to system message only" do
      config =
        echo_config(
          instructions: "System.",
          memory: {Agora.Memory.Buffer, max_messages: 100}
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, _} = Agent.run(pid, "Hello")

      assert :ok = Agent.clear_memory(pid)

      messages = Agent.get_messages(pid)
      assert length(messages) == 1
      assert hd(messages).role == :system
    end

    test "error when no memory configured" do
      config = echo_config()
      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :memory_error, message: message}} = Agent.clear_memory(pid)
      assert message =~ "No memory backend configured"
    end

    test "agent usable after clear" do
      config =
        echo_config(
          instructions: "System.",
          memory: {Agora.Memory.Buffer, max_messages: 100}
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, _} = Agent.run(pid, "Before clear")
      :ok = Agent.clear_memory(pid)
      {:ok, resp} = Agent.run(pid, "After clear")

      assert resp.content == "Echo: After clear"
      messages = Agent.get_messages(pid)
      # system + user + assistant (only from post-clear run)
      assert length(messages) == 3
    end
  end

  describe "memory save error" do
    test "save failure on successful run returns memory_error" do
      config =
        echo_config(memory: {Agora.Memory.FailingSaveBackend, []})

      {:ok, pid} = Agent.start_link(config: config)

      assert {:error, %Error{type: :memory_error, message: "Simulated save failure"}} =
               Agent.run(pid, "Hello")
    end

    test "save failure preserves idle status" do
      config =
        echo_config(memory: {Agora.Memory.FailingSaveBackend, []})

      {:ok, pid} = Agent.start_link(config: config)
      {:error, _} = Agent.run(pid, "Hello")

      assert Agent.get_status(pid) == :idle
    end

    test "save failure on failed run attaches memory_error to metadata" do
      config =
        echo_config(
          memory: {Agora.Memory.FailingSaveBackend, []},
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "API down"
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      assert {:error, %Error{type: :provider_error} = error} = Agent.run(pid, "Hello")

      # Memory error should be attached to original error's metadata
      assert error.metadata[:memory_error] =~ "Simulated save failure"
    end
  end

  describe "no-memory regression" do
    test "memory: nil behaves identically to current" do
      config = echo_config(memory: nil)
      {:ok, pid} = Agent.start_link(config: config)

      {:ok, resp} = Agent.run(pid, "Hello!")
      assert resp.content == "Echo: Hello!"

      messages = Agent.get_messages(pid)
      assert length(messages) == 2
    end
  end

  describe "memory + middleware compose" do
    test "middleware doesn't interfere with save" do
      # Simple pass-through middleware
      middleware = [
        fn ctx, next -> next.(ctx) end
      ]

      config =
        echo_config(
          memory: {Agora.Memory.Buffer, max_messages: 100},
          middleware: middleware
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, _} = Agent.run(pid, "Hello")

      messages = Agent.get_messages(pid)
      assert length(messages) == 2
    end
  end

  describe "invalid memory module config" do
    test "non-existent module returns init error" do
      config = echo_config(memory: {NonExistentModule, []})

      Process.flag(:trap_exit, true)

      assert {:error, %Error{type: :memory_error, message: message}} =
               Agent.start_link(config: config)

      assert message =~ "could not be loaded"
    end
  end

  describe "restart semantics" do
    test "child_spec returns :transient with memory" do
      config = echo_config(memory: {Agora.Memory.Buffer, max_messages: 10})
      spec = Agent.child_spec(config: config)
      assert spec.restart == :transient
    end

    test "child_spec returns :temporary without memory" do
      config = echo_config(memory: nil)
      spec = Agent.child_spec(config: config)
      assert spec.restart == :temporary
    end
  end
end
