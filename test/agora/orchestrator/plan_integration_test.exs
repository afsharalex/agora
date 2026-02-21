defmodule Agora.Orchestrator.PlanIntegrationTest do
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

  describe "happy path — 1-step plan" do
    test "planner creates plan → worker executes → planner reviews COMPLETE" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             Message.assistant(
               "PLAN\nSTEP:1:worker:Do the research\nEND_PLAN"
             )}

          _ ->
            {:ok, Message.assistant("REVIEW:COMPLETE:Research complete")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Research findings here")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:ok, %Message{content: "Research complete"}} = Runner.run(pid, "Research AI trends")

      history = Runner.get_history(pid)
      # planner (plan) → worker (execute) → planner (review)
      assert length(history) == 3
      assert Enum.at(history, 0).agent == :planner
      assert Enum.at(history, 1).agent == :worker
      assert Enum.at(history, 2).agent == :planner
    end
  end

  describe "multi-step with dependencies" do
    test "2-step plan with step 2 depending on step 1" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             Message.assistant(
               "PLAN\nSTEP:1:researcher:Research the topic\nSTEP:2:writer:Write the draft:DEP:1\nEND_PLAN"
             )}

          # Reviews after step 1 and step 2
          _ ->
            {:ok, Message.assistant("REVIEW:CONTINUE:Next step")}
        end
      end

      worker_counter = :counters.new(1, [:atomics])

      researcher_fn = fn _messages, _config ->
        {:ok, Message.assistant("Research results")}
      end

      writer_fn = fn messages, _config ->
        wn = :counters.get(worker_counter, 1) + 1
        :counters.put(worker_counter, 1, wn)

        # Writer should receive context from researcher
        last_user = Enum.find(messages, &(&1.role == :user))
        content = last_user && last_user.content || ""

        {:ok, Message.assistant("Draft based on: #{content}")}
      end

      agents = %{
        planner: function_config(planner_fn),
        researcher: function_config(researcher_fn),
        writer: function_config(writer_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:ok, %Message{}} = Runner.run(pid, "Write about AI")

      history = Runner.get_history(pid)
      agents_in_order = Enum.map(history, & &1.agent)

      # planner(plan), researcher(step1), planner(review1),
      # writer(step2), planner(review2) → done (all_done from next/2 executing)
      assert :planner in agents_in_order
      assert :researcher in agents_in_order
      assert :writer in agents_in_order

      # Researcher runs before writer
      researcher_idx = Enum.find_index(agents_in_order, &(&1 == :researcher))
      writer_idx = Enum.find_index(agents_in_order, &(&1 == :writer))
      assert researcher_idx < writer_idx
    end
  end

  describe "retry path" do
    test "worker fails → planner says RETRY → second attempt succeeds" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             Message.assistant("PLAN\nSTEP:1:worker:Do task\nEND_PLAN")}

          2 ->
            {:ok, Message.assistant("REVIEW:RETRY:Try again")}

          _ ->
            {:ok, Message.assistant("REVIEW:COMPLETE:Done after retry")}
        end
      end

      worker_counter = :counters.new(1, [:atomics])

      worker_fn = fn _messages, _config ->
        wn = :counters.get(worker_counter, 1) + 1
        :counters.put(worker_counter, 1, wn)

        if wn == 1 do
          {:error, Error.new(:provider_error, "First attempt failed")}
        else
          {:ok, Message.assistant("Success on retry")}
        end
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:ok, %Message{content: "Done after retry"}} = Runner.run(pid, "Do it")
    end
  end

  describe "reassign path" do
    test "worker fails → planner says REASSIGN → other worker succeeds" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             Message.assistant("PLAN\nSTEP:1:worker_a:Do task\nEND_PLAN")}

          2 ->
            {:ok, Message.assistant("REVIEW:REASSIGN:worker_b:Try other worker")}

          _ ->
            {:ok, Message.assistant("REVIEW:COMPLETE:Done via reassignment")}
        end
      end

      worker_a_fn = fn _messages, _config ->
        {:error, Error.new(:provider_error, "Worker A failed")}
      end

      worker_b_fn = fn _messages, _config ->
        {:ok, Message.assistant("Worker B succeeded")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker_a: function_config(worker_a_fn),
        worker_b: function_config(worker_b_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:ok, %Message{content: "Done via reassignment"}} = Runner.run(pid, "Do it")
    end
  end

  describe "replan path" do
    test "planner says REPLAN → new plan created and executed" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            # First plan
            {:ok,
             Message.assistant("PLAN\nSTEP:1:worker:Bad approach\nEND_PLAN")}

          2 ->
            # Review after step 1 → replan
            {:ok, Message.assistant("REVIEW:REPLAN:Need different approach")}

          3 ->
            # Second plan
            {:ok,
             Message.assistant("PLAN\nSTEP:1:worker:Better approach\nEND_PLAN")}

          _ ->
            {:ok, Message.assistant("REVIEW:COMPLETE:Done after replan")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Worker output")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:ok, %Message{content: "Done after replan"}} = Runner.run(pid, "Do it")
    end
  end

  describe "stall detection" do
    test "step fails, retries exhausted, planner says RETRY → error returned" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            {:ok,
             Message.assistant("PLAN\nSTEP:1:worker:Do task\nEND_PLAN")}

          _ ->
            {:ok, Message.assistant("REVIEW:RETRY:Try again")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:error, Error.new(:provider_error, "Always fails")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner, max_retries_per_step: 1]
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "Do it")

      assert msg =~ "exhausted retries"
    end
  end

  describe "replan limit" do
    test "max replans exceeded → error returned" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        cond do
          rem(n, 2) == 1 ->
            {:ok,
             Message.assistant("PLAN\nSTEP:1:worker:Try again\nEND_PLAN")}

          true ->
            {:ok, Message.assistant("REVIEW:REPLAN:Not working")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Worker output")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner, max_replans: 1]
        )

      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Runner.run(pid, "Do it")

      assert msg =~ "Replan limit"
    end
  end

  describe "CONTINUE into blocked graph" do
    test "step fails → CONTINUE → blocked → planner consulted → REPLAN → success" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 ->
            # Plan with dependency chain
            {:ok,
             Message.assistant(
               "PLAN\nSTEP:1:worker:First task\nSTEP:2:worker:Second task:DEP:1\nEND_PLAN"
             )}

          2 ->
            # Review after step 1 fails → continue (bad decision)
            {:ok, Message.assistant("REVIEW:CONTINUE:Keep going")}

          3 ->
            # Blocked prompt → replan
            {:ok, Message.assistant("REVIEW:REPLAN:Need simpler plan")}

          4 ->
            # New plan with no deps
            {:ok,
             Message.assistant("PLAN\nSTEP:1:worker:Simple task\nEND_PLAN")}

          _ ->
            {:ok, Message.assistant("REVIEW:COMPLETE:Finally done")}
        end
      end

      worker_counter = :counters.new(1, [:atomics])

      worker_fn = fn _messages, _config ->
        wn = :counters.get(worker_counter, 1) + 1
        :counters.put(worker_counter, 1, wn)

        if wn == 1 do
          {:error, Error.new(:provider_error, "First task failed")}
        else
          {:ok, Message.assistant("Task succeeded")}
        end
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:ok, %Message{content: "Finally done"}} = Runner.run(pid, "Complex task")
    end
  end

  describe "cross-cutting — cancel_token" do
    test "cancels mid-plan → :cancelled error" do
      token = CancelToken.new()
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        {:ok,
         Message.assistant(
           "PLAN\nSTEP:1:worker:Long task\nSTEP:2:worker:Another task\nEND_PLAN"
         )}
      end

      worker_fn = fn _messages, _config ->
        # Cancel after first worker runs
        CancelToken.cancel(token)
        {:ok, Message.assistant("Worker done")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner],
          cancel_token: token
        )

      assert {:error, %Error{type: :cancelled}} = Runner.run(pid, "Long task")
    end
  end

  describe "cross-cutting — telemetry" do
    test "emits orchestrator run/step events with telemetry_metadata" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "plan-integration-#{inspect(ref)}",
        [
          [:agora, :orchestrator, :run, :start],
          [:agora, :orchestrator, :run, :stop],
          [:agora, :orchestrator, :step, :start],
          [:agora, :orchestrator, :step, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 -> {:ok, Message.assistant("PLAN\nSTEP:1:worker:Task\nEND_PLAN")}
          _ -> {:ok, Message.assistant("REVIEW:COMPLETE:Done")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant("Output")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner],
          telemetry_metadata: %{custom: "test_value"}
        )

      {:ok, _} = Runner.run(pid, "Task")

      assert_receive {:telemetry, [:agora, :orchestrator, :run, :start], _,
                      %{orchestrator: Agora.Orchestrator.Plan, custom: "test_value"}}

      assert_receive {:telemetry, [:agora, :orchestrator, :run, :stop], _,
                      %{orchestrator: Agora.Orchestrator.Plan, custom: "test_value"}}

      :telemetry.detach("plan-integration-#{inspect(ref)}")
    end
  end

  describe "nil worker content" do
    test "worker returns nil content → artifact stored, planner reviews" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        case n do
          1 -> {:ok, Message.assistant("PLAN\nSTEP:1:worker:Task\nEND_PLAN")}
          _ -> {:ok, Message.assistant("REVIEW:COMPLETE:Done despite nil")}
        end
      end

      worker_fn = fn _messages, _config ->
        {:ok, Message.assistant(nil, [])}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(worker_fn)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:ok, %Message{content: "Done despite nil"}} = Runner.run(pid, "Task")
    end
  end

  describe "runner remains alive after errors" do
    test "plan mode error does not crash runner" do
      counter = :counters.new(1, [:atomics])

      planner_fn = fn _messages, _config ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        # Always output bad plan
        {:ok, Message.assistant("No valid plan here")}
      end

      agents = %{
        planner: function_config(planner_fn),
        worker: function_config(fn _, _ -> {:ok, Message.assistant("ok")} end)
      }

      {:ok, pid} =
        Runner.start_link(
          orchestrator: Agora.Orchestrator.Plan,
          agents: agents,
          orchestrator_opts: [planner_agent: :planner]
        )

      assert {:error, %Error{type: :orchestration_error}} = Runner.run(pid, "Bad")
      assert Process.alive?(pid)
    end
  end
end
