defmodule Agora.ConvenienceApiTest do
  use ExUnit.Case, async: false

  alias Agora.{AgentConfig, Error, Message}

  describe "Agora.run/2" do
    test "string input returns {:ok, %Message{}}" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      assert {:ok, %Message{role: :assistant, content: "Echo: Hello"}} =
               Agora.run(config, "Hello")
    end

    test "Message input works" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      msg = Message.user("Hello from Message")

      assert {:ok, %Message{role: :assistant, content: "Echo: Hello from Message"}} =
               Agora.run(config, msg)
    end

    test "agent process is dead after run/2 returns" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      # Get the pid by observing children before and after
      children_before = DynamicSupervisor.which_children(Agora.Agent.Supervisor)

      {:ok, _response} = Agora.run(config, "Hello")

      children_after = DynamicSupervisor.which_children(Agora.Agent.Supervisor)

      # No new children should remain
      assert length(children_after) == length(children_before)
    end

    test "provider error propagates as {:error, %Error{}}" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "test error"
          ]
        )

      assert {:error, %Error{type: :provider_error, message: "test error"}} =
               Agora.run(config, "Hello")
    end

    test "tool call cycle completes with Echo :function mode" do
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          tools: [Agora.Tool.Calculator],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count == 0 do
                {:ok,
                 Message.assistant(nil, [
                   Agora.ToolCall.new(%{
                     id: "call_1",
                     name: "calculator",
                     arguments: %{"operation" => "add", "a" => 1, "b" => 2}
                   })
                 ])}
              else
                last_content =
                  messages
                  |> Enum.reverse()
                  |> Enum.find_value(fn
                    %Message{role: :tool} = m -> hd(m.tool_results).content
                    _ -> nil
                  end)

                {:ok, Message.assistant("Result: #{last_content}")}
              end
            end
          ]
        )

      assert {:ok, %Message{content: "Result: 3"}} = Agora.run(config, "Add 1 and 2")
    end

    test "agent cleanup happens even on error" do
      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              count = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if count == 0 do
                {:error, Error.new(:provider_error, "boom")}
              else
                {:ok, Message.assistant("ok")}
              end
            end
          ]
        )

      children_before = DynamicSupervisor.which_children(Agora.Agent.Supervisor)
      assert {:error, %Error{}} = Agora.run(config, "Hello")
      children_after = DynamicSupervisor.which_children(Agora.Agent.Supervisor)
      assert length(children_after) == length(children_before)
    end
  end

  describe "Agora.stream/2" do
    test "returns {:ok, stream} and events are enumerable" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      assert {:ok, stream} = Agora.stream(config, "Hello")

      events = Enum.to_list(stream)
      assert length(events) > 0

      types = Enum.map(events, & &1.type)
      assert :text_delta in types
      assert :message_complete in types
      assert :done in types
    end

    test "agent process is dead after stream fully consumed" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      children_before = DynamicSupervisor.which_children(Agora.Agent.Supervisor)

      {:ok, stream} = Agora.stream(config, "Hello")
      _events = Enum.to_list(stream)

      # Give supervisor time to clean up
      Process.sleep(50)

      children_after = DynamicSupervisor.which_children(Agora.Agent.Supervisor)
      assert length(children_after) == length(children_before)
    end

    test "Enum.take early termination still cleans up agent" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [echo_mode: :static, echo_response: "Hello World Test"]
        )

      children_before = DynamicSupervisor.which_children(Agora.Agent.Supervisor)

      {:ok, stream} = Agora.stream(config, "Hello")
      _events = Enum.take(stream, 1)

      # Give supervisor time to clean up
      Process.sleep(50)

      children_after = DynamicSupervisor.which_children(Agora.Agent.Supervisor)
      assert length(children_after) == length(children_before)
    end

    test "caller crash cleans up agent" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      children_before = DynamicSupervisor.which_children(Agora.Agent.Supervisor)
      test_pid = self()

      # Spawn an unlinked process that gets the stream but crashes
      pid =
        spawn(fn ->
          {:ok, _stream} = Agora.stream(config, "Hello")
          send(test_pid, :stream_created)

          receive do
            :never -> :ok
          end
        end)

      assert_receive :stream_created, 5000

      # Give the monitor time to set up
      Process.sleep(50)

      # Kill the process
      Process.exit(pid, :kill)

      # Wait for cleanup
      Process.sleep(100)

      children_after = DynamicSupervisor.which_children(Agora.Agent.Supervisor)
      assert length(children_after) == length(children_before)
    end

    test "provider error during streaming delivered as :error event" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "stream error"
          ]
        )

      {:ok, stream} = Agora.stream(config, "Hello")
      events = Enum.to_list(stream)

      error_events = Enum.filter(events, &(&1.type == :error))
      assert length(error_events) > 0

      error_event = hd(error_events)
      assert %Error{type: :provider_error} = error_event.data
    end

    test "text deltas can be collected from stream" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      {:ok, stream} = Agora.stream(config, "Hi")

      text =
        stream
        |> Stream.filter(&(&1.type == :text_delta))
        |> Enum.map(& &1.data.text)
        |> Enum.join()

      assert text == "Echo: Hi"
    end
  end
end
