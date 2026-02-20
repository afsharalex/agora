defmodule Agora.Orchestrator.SupervisorTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message}
  alias Agora.Orchestrator.Supervisor, as: SupervisorOrch

  defp init_config(opts \\ %{}) do
    Map.merge(
      %{
        agent_names: [:boss, :worker_a, :worker_b],
        supervisor_agent: :boss
      },
      opts
    )
  end

  describe "init/1" do
    test "identifies supervisor and workers" do
      {:ok, state} = SupervisorOrch.init(init_config())
      assert state.supervisor == :boss
      assert :worker_a in state.workers
      assert :worker_b in state.workers
      assert :boss not in state.workers
    end

    test "builds worker lookup map" do
      {:ok, state} = SupervisorOrch.init(init_config())
      assert state.worker_lookup == %{"worker_a" => :worker_a, "worker_b" => :worker_b}
    end

    test "starts in supervisor phase" do
      {:ok, state} = SupervisorOrch.init(init_config())
      assert state.phase == :supervisor
    end

    test "errors when supervisor_agent missing" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               SupervisorOrch.init(%{agent_names: [:a, :b]})

      assert msg =~ "supervisor_agent"
    end

    test "accepts custom parse_delegation function" do
      custom_fn = fn _content, _lookup -> :no_delegation end
      {:ok, state} = SupervisorOrch.init(init_config(%{parse_delegation: custom_fn}))
      assert state.parse_fn == custom_fn
    end

    test "errors when parse_delegation is not a 2-arity function" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               SupervisorOrch.init(init_config(%{parse_delegation: "not a function"}))

      assert msg =~ "parse_delegation"
    end

    test "errors when parse_delegation has wrong arity" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               SupervisorOrch.init(init_config(%{parse_delegation: fn _x -> :ok end}))

      assert msg =~ "parse_delegation"
    end
  end

  describe "next/2 — supervisor phase" do
    test "sends original input on first turn" do
      {:ok, state} = SupervisorOrch.init(init_config())
      input = Message.user("Do something")
      context = %{original_input: input, history: []}

      assert {:next, :boss, ^input, _state} = SupervisorOrch.next(state, context)
    end

    test "sends worker result on subsequent turns" do
      {:ok, state} = SupervisorOrch.init(init_config())
      state = %{state | last_worker_result: "worker output"}

      context = %{original_input: Message.user("original"), history: []}

      assert {:next, :boss, msg, _state} = SupervisorOrch.next(state, context)
      assert msg.content == "Worker result: worker output"
    end
  end

  describe "next/2 — worker phase" do
    test "sends delegation message to worker" do
      {:ok, state} = SupervisorOrch.init(init_config())
      state = %{state | phase: {:worker, :worker_a}, delegation_message: "do task X"}

      context = %{original_input: Message.user("original"), history: []}

      assert {:next, :worker_a, msg, _state} = SupervisorOrch.next(state, context)
      assert msg.content == "do task X"
    end
  end

  describe "handle_result/3 — supervisor phase with delegation" do
    test "parses DELEGATE directive and transitions to worker phase" do
      {:ok, state} = SupervisorOrch.init(init_config())
      msg = Message.assistant("DELEGATE:worker_a:Please handle this task")

      assert {:continue, new_state} = SupervisorOrch.handle_result(state, :boss, {:ok, msg})
      assert new_state.phase == {:worker, :worker_a}
      assert new_state.delegation_message == "Please handle this task"
    end

    test "parses delegation with hyphenated worker names" do
      config = %{
        agent_names: [:boss, :"worker-a", :"worker-b"],
        supervisor_agent: :boss
      }

      {:ok, state} = SupervisorOrch.init(config)
      msg = Message.assistant("DELEGATE:worker-a:do the task")

      assert {:continue, new_state} = SupervisorOrch.handle_result(state, :boss, {:ok, msg})
      assert new_state.phase == {:worker, :"worker-a"}
      assert new_state.delegation_message == "do the task"
    end

    test "returns done when no delegation found" do
      {:ok, state} = SupervisorOrch.init(init_config())
      msg = Message.assistant("Here is the final answer")

      assert {:done, ^msg, _state} = SupervisorOrch.handle_result(state, :boss, {:ok, msg})
    end

    test "errors on unknown worker name — atom safety" do
      {:ok, state} = SupervisorOrch.init(init_config())
      msg = Message.assistant("DELEGATE:unknown_agent:do something")

      assert {:error, %Error{type: :orchestration_error, message: message}, _state} =
               SupervisorOrch.handle_result(state, :boss, {:ok, msg})

      assert message =~ "Unknown worker agent"
      assert message =~ "unknown_agent"
    end

    test "never calls String.to_atom on model output" do
      {:ok, state} = SupervisorOrch.init(init_config())

      # Uses a valid \w+ name that isn't in the worker lookup — validates against map, not to_atom
      msg = Message.assistant("DELEGATE:totally_unknown_worker:task")

      assert {:error, %Error{type: :orchestration_error, message: message}, _state} =
               SupervisorOrch.handle_result(state, :boss, {:ok, msg})

      assert message =~ "Unknown worker agent"
    end

    test "handles nil content from supervisor" do
      {:ok, state} = SupervisorOrch.init(init_config())
      msg = Message.assistant(nil, [])

      # No delegation found — just return done
      assert {:done, ^msg, _state} = SupervisorOrch.handle_result(state, :boss, {:ok, msg})
    end
  end

  describe "handle_result/3 — worker phase" do
    test "stores result and switches back to supervisor" do
      {:ok, state} = SupervisorOrch.init(init_config())
      state = %{state | phase: {:worker, :worker_a}}
      msg = Message.assistant("worker output")

      assert {:continue, new_state} =
               SupervisorOrch.handle_result(state, :worker_a, {:ok, msg})

      assert new_state.phase == :supervisor
      assert new_state.last_worker_result == "worker output"
      assert new_state.delegation_message == nil
    end

    test "handles nil content from worker" do
      {:ok, state} = SupervisorOrch.init(init_config())
      state = %{state | phase: {:worker, :worker_a}}
      msg = Message.assistant(nil, [])

      assert {:continue, new_state} =
               SupervisorOrch.handle_result(state, :worker_a, {:ok, msg})

      assert new_state.last_worker_result == ""
    end
  end

  describe "handle_result/3 — error propagation" do
    test "propagates errors from supervisor" do
      {:ok, state} = SupervisorOrch.init(init_config())
      error = Error.new(:provider_error, "fail")

      assert {:error, ^error, _state} =
               SupervisorOrch.handle_result(state, :boss, {:error, error})
    end

    test "propagates errors from worker" do
      {:ok, state} = SupervisorOrch.init(init_config())
      state = %{state | phase: {:worker, :worker_a}}
      error = Error.new(:provider_error, "fail")

      assert {:error, ^error, _state} =
               SupervisorOrch.handle_result(state, :worker_a, {:error, error})
    end
  end

  describe "custom parse_delegation" do
    test "uses custom parser function" do
      custom_fn = fn content, worker_lookup ->
        case content do
          "ROUTE:" <> rest ->
            [name, msg] = String.split(rest, ":", parts: 2)

            case Map.fetch(worker_lookup, name) do
              {:ok, atom} -> {:delegate, atom, msg}
              :error -> {:error, Error.new(:orchestration_error, "Unknown: #{name}")}
            end

          _ ->
            :no_delegation
        end
      end

      {:ok, state} = SupervisorOrch.init(init_config(%{parse_delegation: custom_fn}))
      msg = Message.assistant("ROUTE:worker_a:custom task")

      assert {:continue, new_state} = SupervisorOrch.handle_result(state, :boss, {:ok, msg})
      assert new_state.phase == {:worker, :worker_a}
      assert new_state.delegation_message == "custom task"
    end
  end
end
