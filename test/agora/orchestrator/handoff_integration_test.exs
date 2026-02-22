defmodule Agora.Orchestrator.HandoffIntegrationTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, CancelToken, Error, Message}
  alias Agora.Orchestrator.Runner

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  defp function_config(fun) do
    echo_config(provider_opts: [echo_mode: :function, echo_function: fun])
  end

  describe "happy path" do
    test "Agent A hands off to Agent B, B completes" do
      a_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "Routing to support",
           metadata: %{handoff: %{target: "agent_b", message: "Customer needs help"}}
         )}
      end

      b_fn = fn _messages, _config ->
        {:ok, Message.assistant("Issue resolved")}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: function_config(b_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a]
        )

      assert {:ok, %Message{content: "Issue resolved"}} = Runner.run(pid, "Help me")

      history = Runner.get_history(pid)
      assert length(history) == 2
      assert Enum.at(history, 0).agent == :agent_a
      assert Enum.at(history, 1).agent == :agent_b
    end
  end

  describe "multi-hop chain" do
    test "A → B → C → completion with history tracking" do
      counter = :counters.new(1, [:atomics])

      a_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "Triaging to support",
           metadata: %{handoff: %{target: "agent_b", message: "Billing issue"}}
         )}
      end

      b_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "Escalating to specialist",
           metadata: %{handoff: %{target: "agent_c", message: "Complex billing case"}}
         )}
      end

      c_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        {:ok, Message.assistant("Billing resolved: refund issued")}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: function_config(b_fn),
        agent_c: function_config(c_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a]
        )

      assert {:ok, %Message{content: "Billing resolved: refund issued"}} =
               Runner.run(pid, "I have a billing problem")

      history = Runner.get_history(pid)
      agents_in_order = Enum.map(history, & &1.agent)
      assert agents_in_order == [:agent_a, :agent_b, :agent_c]
    end
  end

  describe "directive fallback" do
    test "A emits HANDOFF directive, B receives and completes" do
      a_fn = fn _messages, _config ->
        {:ok, Message.assistant("HANDOFF:agent_b:Please handle this request")}
      end

      b_fn = fn _messages, _config ->
        {:ok, Message.assistant("Handled successfully")}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: function_config(b_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a]
        )

      assert {:ok, %Message{content: "Handled successfully"}} = Runner.run(pid, "hello")

      history = Runner.get_history(pid)
      assert length(history) == 2
    end
  end

  describe "max hops exceeded" do
    test "chain exceeds limit returns orchestration_error" do
      # Both agents just bounce back and forth
      a_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "go",
           metadata: %{handoff: %{target: "agent_b", message: "bounce"}}
         )}
      end

      b_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "go",
           metadata: %{handoff: %{target: "agent_a", message: "bounce"}}
         )}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: function_config(b_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a, max_hops: 3]
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "start bouncing")

      assert msg =~ "Max hops"
    end
  end

  describe "no-repeat window" do
    test "A → B → A attempted with window=2 returns error" do
      counter = :counters.new(1, [:atomics])

      a_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "go",
           metadata: %{handoff: %{target: "agent_b", message: "to b"}}
         )}
      end

      b_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        {:ok,
         Message.new(:assistant, "go",
           metadata: %{handoff: %{target: "agent_a", message: "back to a"}}
         )}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: function_config(b_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a, no_repeat_window: 2]
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "start loop")

      assert msg =~ "no_repeat_window"
    end
  end

  describe "self-handoff rejected" do
    test "A hands off to A returns error" do
      a_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "go",
           metadata: %{handoff: %{target: "agent_a", message: "self"}}
         )}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: echo_config()
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a]
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "self loop")

      assert msg =~ "Self-handoff"
    end
  end

  describe "invalid target" do
    test "agent produces unknown name returns error" do
      a_fn = fn _messages, _config ->
        {:ok,
         Message.new(:assistant, "go",
           metadata: %{handoff: %{target: "nonexistent", message: "bad"}}
         )}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: echo_config()
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a]
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "bad target")

      assert msg =~ "Unknown handoff target"
    end
  end

  describe "cross-cutting — cancel_token" do
    test "cancels mid-chain returns cancelled error" do
      token = CancelToken.new()

      a_fn = fn _messages, _config ->
        # Cancel after first agent runs
        CancelToken.cancel(token)

        {:ok,
         Message.new(:assistant, "routing",
           metadata: %{handoff: %{target: "agent_b", message: "go"}}
         )}
      end

      b_fn = fn _messages, _config ->
        {:ok, Message.assistant("should not reach")}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: function_config(b_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a],
          cancel_token: token
        )

      assert {:error, %Error{type: :cancelled}} = Runner.run(pid, "cancel me")
    end
  end

  describe "nil content handoff" do
    test "agent hands off with nil content → target receives empty string" do
      a_fn = fn _messages, _config ->
        {:ok, Message.new(:assistant, nil, metadata: %{handoff: %{target: "agent_b"}})}
      end

      b_fn = fn messages, _config ->
        last_user = Enum.find(messages, &(&1.role == :user))
        content = if last_user, do: last_user.content, else: "no input"
        {:ok, Message.assistant("Received: '#{content}'")}
      end

      agents = %{
        agent_a: function_config(a_fn),
        agent_b: function_config(b_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Handoff,
          agents: agents,
          orchestrator_opts: [initial_agent: :agent_a]
        )

      assert {:ok, %Message{content: "Received: ''"}} = Runner.run(pid, "test")
    end
  end
end
