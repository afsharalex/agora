defmodule Agora.AgentIntegrationTest do
  @moduledoc """
  End-to-end integration tests: Agent + Echo provider + Calculator tool.
  """

  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig, Message, ToolCall}
  alias Agora.Tool.Calculator

  describe "agent with Calculator tool" do
    test "full tool call cycle: invoke calculator and return result" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          tools: [Calculator],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              has_tool_results = Enum.any?(messages, &(&1.role == :tool))

              if has_tool_results do
                tool_msg = Enum.filter(messages, &(&1.role == :tool)) |> List.last()
                result = hd(tool_msg.tool_results)
                {:ok, Message.assistant("The answer is #{result.content}")}
              else
                call =
                  ToolCall.new(%{
                    id: "calc_1",
                    name: "calculator",
                    arguments: %{"operation" => "add", "a" => 7, "b" => 3}
                  })

                {:ok, Message.assistant(nil, [call])}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, response} = Agent.run(pid, "What is 7 + 3?")

      assert response.content == "The answer is 10"
      assert response.role == :assistant

      # Verify full message sequence
      messages = Agent.get_messages(pid)
      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :tool, :assistant]

      # Verify tool result content
      tool_msg = Enum.at(messages, 2)
      assert length(tool_msg.tool_results) == 1
      result = hd(tool_msg.tool_results)
      assert result.content == "10"
      assert result.is_error == false
      assert result.name == "calculator"
    end

    test "multi-step calculation with conversation persistence" do
      call_count = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          tools: [Calculator],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              :counters.add(call_count, 1, 1)
              count = :counters.get(call_count, 1)
              has_tool_results = Enum.any?(messages, &(&1.role == :tool))

              if has_tool_results and rem(count, 2) == 0 do
                tool_msg = Enum.filter(messages, &(&1.role == :tool)) |> List.last()
                result = hd(tool_msg.tool_results)
                {:ok, Message.assistant("Got #{result.content}")}
              else
                call =
                  ToolCall.new(%{
                    id: "calc_#{count}",
                    name: "calculator",
                    arguments: %{"operation" => "multiply", "a" => 5, "b" => 6}
                  })

                {:ok, Message.assistant(nil, [call])}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)

      # First run
      {:ok, resp1} = Agent.run(pid, "Multiply 5 by 6")
      assert resp1.content == "Got 30"

      # Second run — conversation persists
      {:ok, resp2} = Agent.run(pid, "Do it again")
      assert resp2.content == "Got 30"

      # Verify full history across both runs
      messages = Agent.get_messages(pid)
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end

    test "tool error is fed back to provider" do
      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          tools: [Calculator],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              has_tool_results = Enum.any?(messages, &(&1.role == :tool))

              if has_tool_results do
                tool_msg = Enum.filter(messages, &(&1.role == :tool)) |> List.last()
                result = hd(tool_msg.tool_results)

                if result.is_error do
                  {:ok, Message.assistant("Error: #{result.content}")}
                else
                  {:ok, Message.assistant("OK: #{result.content}")}
                end
              else
                call =
                  ToolCall.new(%{
                    id: "calc_div0",
                    name: "calculator",
                    arguments: %{"operation" => "divide", "a" => 1, "b" => 0}
                  })

                {:ok, Message.assistant(nil, [call])}
              end
            end
          ]
        )

      {:ok, pid} = Agent.start_link(config: config)
      {:ok, response} = Agent.run(pid, "Divide by zero")

      assert response.content == "Error: Division by zero"
    end
  end

  describe "Agora convenience functions" do
    test "start_agent/2 and stop_agent/1" do
      config = AgentConfig.new!(provider: :echo, model: "echo")

      {:ok, pid} = Agora.start_agent(config)
      assert Process.alive?(pid)

      {:ok, response} = Agent.run(pid, "Test")
      assert response.content == "Echo: Test"

      assert :ok = Agora.stop_agent(pid)
      refute Process.alive?(pid)
    end
  end
end
