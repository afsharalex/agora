defmodule Agora.Orchestrator.IntegrationTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message}
  alias Agora.Orchestrator.{Runner, TerminationCondition}
  alias Agora.Tool.FunctionTool

  defp function_config(fun, opts \\ []) do
    defaults = [
      provider: :echo,
      model: "echo",
      provider_opts: [echo_mode: :function, echo_function: fun]
    ]

    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  describe "Agora.start_runner/2 and Agora.stop_runner/1" do
    test "starts and stops runner via convenience functions" do
      agents = %{
        helper: AgentConfig.new!(provider: :echo, model: "echo")
      }

      assert {:ok, pid} =
               Agora.start_runner(
                 orchestrator: Agora.Orchestrator.Single,
                 agents: agents
               )

      assert Process.alive?(pid)

      {:ok, %Message{content: "Echo: Hello!"}} = Runner.run(pid, "Hello!")

      assert :ok = Agora.stop_runner(pid)
      refute Process.alive?(pid)
    end
  end

  describe "agent with tools within orchestration" do
    test "RoundRobin with tool-using agent" do
      add_tool =
        FunctionTool.new!(
          name: "add",
          description: "Add two numbers",
          schema: %{
            "type" => "object",
            "properties" => %{
              "a" => %{"type" => "number"},
              "b" => %{"type" => "number"}
            },
            "required" => ["a", "b"]
          },
          function: fn %{"a" => a, "b" => b}, _ctx -> {:ok, "#{a + b}"} end
        )

      counter = :counters.new(1, [:atomics])

      # Agent that calls a tool on first iteration, then returns text
      agent_fn = fn messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        has_tool_result = Enum.any?(messages, &(&1.role == :tool))

        cond do
          n == 1 && !has_tool_result ->
            tool_call = %Agora.ToolCall{
              id: "call_1",
              name: "add",
              arguments: %{"a" => 2, "b" => 3}
            }

            {:ok, Message.assistant(nil, [tool_call])}

          has_tool_result ->
            {:ok, Message.assistant("The sum is 5")}

          true ->
            {:ok, Message.assistant("Processed: #{List.last(messages).content}")}
        end
      end

      agents = %{
        calculator: function_config(agent_fn, tools: [add_tool]),
        summarizer:
          function_config(fn _msgs, _config ->
            {:ok, Message.assistant("DONE: summary complete")}
          end)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.RoundRobin,
          agents: agents,
          termination: TerminationCondition.keyword_match(["DONE"])
        )

      assert {:ok, %Message{content: "DONE: summary complete"}} = Runner.run(pid, "Calculate 2+3")
    end
  end

  describe "multi-run orchestration" do
    test "runner handles multiple sequential runs" do
      counter = :counters.new(1, [:atomics])

      fun = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Run response #{n}")}
      end

      agents = %{
        helper: function_config(fun)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Single,
          agents: agents
        )

      {:ok, msg1} = Runner.run(pid, "First")
      {:ok, msg2} = Runner.run(pid, "Second")
      {:ok, msg3} = Runner.run(pid, "Third")

      assert msg1.content == "Run response 1"
      assert msg2.content == "Run response 2"
      assert msg3.content == "Run response 3"
    end
  end
end
