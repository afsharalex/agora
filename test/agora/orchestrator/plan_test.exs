defmodule Agora.Orchestrator.PlanTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message}
  alias Agora.Orchestrator.Plan

  defp init_config(opts \\ %{}) do
    Map.merge(
      %{
        agent_names: [:planner, :researcher, :writer],
        planner_agent: :planner
      },
      opts
    )
  end

  defp plan_response(steps) do
    step_lines =
      Enum.map_join(steps, "\n", fn step ->
        base = "STEP:#{step.id}:#{step.agent}:#{step.desc}"
        if step[:deps], do: base <> ":DEP:#{Enum.join(step.deps, ",")}", else: base
      end)

    "PLAN\n#{step_lines}\nEND_PLAN"
  end

  defp make_context(task \\ "Do the thing") do
    %{original_input: Message.user(task), history: []}
  end

  defp init_and_plan(config_opts \\ %{}, plan_steps) do
    {:ok, state} = Plan.init(init_config(config_opts))

    # Simulate planning phase
    {:next, :planner, _prompt, state} = Plan.next(state, make_context())

    content = plan_response(plan_steps)
    msg = Message.assistant(content)
    {:continue, state} = Plan.handle_result(state, :planner, {:ok, msg})
    state
  end

  # --- init/1 ---

  describe "init/1" do
    test "valid config → :planning phase, sorted workers, agent_lookup" do
      {:ok, state} = Plan.init(init_config())

      assert state.phase == :planning
      assert state.planner == :planner
      assert state.agents == [:researcher, :writer]
      assert state.agent_lookup == %{"researcher" => :researcher, "writer" => :writer}
      assert state.plan == []
      assert state.artifacts == %{}
      assert state.replan_count == 0
      assert state.failure_count == 0
    end

    test "missing :planner_agent → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(%{agent_names: [:a, :b]})

      assert msg =~ "planner_agent"
    end

    test "planner not in agent_names → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(%{agent_names: [:a, :b], planner_agent: :planner})

      assert msg =~ "must be in agent_names"
    end

    test "custom parse_plan fn accepted (2-arity)" do
      custom_fn = fn _content, _lookup -> {:ok, []} end
      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      assert state.parse_plan == custom_fn
    end

    test "custom parse_review fn accepted (1-arity)" do
      custom_fn = fn _content -> {:ok, {:complete, "done"}} end
      {:ok, state} = Plan.init(init_config(%{parse_review: custom_fn}))
      assert state.parse_review == custom_fn
    end

    test "invalid parse_plan arity → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(init_config(%{parse_plan: fn _x -> :ok end}))

      assert msg =~ "parse_plan"
    end

    test "invalid parse_review arity → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(init_config(%{parse_review: fn _a, _b -> :ok end}))

      assert msg =~ "parse_review"
    end

    test "non-function parse_plan → error" do
      assert {:error, %Error{type: :orchestration_error}} =
               Plan.init(init_config(%{parse_plan: "not a function"}))
    end

    test "non-function parse_review → error" do
      assert {:error, %Error{type: :orchestration_error}} =
               Plan.init(init_config(%{parse_review: :atom}))
    end

    test "default limits applied (2/2/10)" do
      {:ok, state} = Plan.init(init_config())
      assert state.max_retries_per_step == 2
      assert state.max_replans == 2
      assert state.max_plan_steps == 10
    end

    test "custom limits respected" do
      {:ok, state} =
        Plan.init(
          init_config(%{
            max_retries_per_step: 5,
            max_replans: 3,
            max_plan_steps: 20
          })
        )

      assert state.max_retries_per_step == 5
      assert state.max_replans == 3
      assert state.max_plan_steps == 20
    end

    test "negative max_retries_per_step → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(init_config(%{max_retries_per_step: -1}))

      assert msg =~ "max_retries_per_step"
      assert msg =~ "non-negative integer"
    end

    test "non-integer max_replans → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(init_config(%{max_replans: "two"}))

      assert msg =~ "max_replans"
      assert msg =~ "non-negative integer"
    end

    test "nil max_plan_steps → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(init_config(%{max_plan_steps: nil}))

      assert msg =~ "max_plan_steps"
      assert msg =~ "non-negative integer"
    end

    test "float max_retries_per_step → error" do
      assert {:error, %Error{type: :orchestration_error, message: msg}} =
               Plan.init(init_config(%{max_retries_per_step: 2.5}))

      assert msg =~ "max_retries_per_step"
    end

    test "zero limits are accepted" do
      {:ok, state} =
        Plan.init(
          init_config(%{
            max_retries_per_step: 0,
            max_replans: 0,
            max_plan_steps: 0
          })
        )

      assert state.max_retries_per_step == 0
      assert state.max_replans == 0
      assert state.max_plan_steps == 0
    end

    test "workers sorted alphabetically" do
      {:ok, state} =
        Plan.init(%{
          agent_names: [:planner, :zoe, :alice, :bob],
          planner_agent: :planner
        })

      assert state.agents == [:alice, :bob, :zoe]
    end

    test "planner excluded from workers" do
      {:ok, state} = Plan.init(init_config())
      refute :planner in state.agents
      refute Map.has_key?(state.agent_lookup, "planner")
    end
  end

  # --- next/2 — planning phase ---

  describe "next/2 — planning phase" do
    test "sends prompt to planner with sorted agent list" do
      {:ok, state} = Plan.init(init_config())
      context = make_context("Write an essay")

      {:next, :planner, msg, _state} = Plan.next(state, context)

      assert msg.role == :user
      assert msg.content =~ "researcher, writer"
      assert msg.content =~ "Write an essay"
    end

    test "captures original_task from context" do
      {:ok, state} = Plan.init(init_config())
      context = make_context("My task here")

      {:next, :planner, _msg, state} = Plan.next(state, context)
      assert state.original_task == "My task here"
    end

    test "replan prompt includes failure context and artifacts" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research topic"}
        ])

      # Simulate step execution + review leading to replan
      step = hd(state.plan)
      msg = Message.assistant("Research results here")

      # Execute step
      state = %{state | current_step: step.id}
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, msg})

      # Review: REPLAN
      review_msg = Message.assistant("REVIEW:REPLAN:Need different approach")
      {:continue, state, _events} = Plan.handle_result(state, :planner, {:ok, review_msg})

      assert state.phase == :planning
      assert state.replan_count == 1

      # Now next/2 should build replan prompt
      {:next, :planner, prompt_msg, _state} = Plan.next(state, make_context())
      assert prompt_msg.content =~ "previous plan did not succeed"
      assert prompt_msg.content =~ "COMPLETED WORK SO FAR"
    end
  end

  # --- next/2 — executing phase ---

  describe "next/2 — executing phase" do
    test "sends step task to assigned worker" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research the topic"}
        ])

      {:next, :researcher, msg, state} = Plan.next(state, make_context())
      assert msg.content =~ "Research the topic"
      assert state.current_step == 1
    end

    test "includes dependency outputs in input (context slicing)" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write draft", deps: [1]}
        ])

      # Execute step 1
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant("Research findings here")
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      # Review: CONTINUE
      review_msg = Message.assistant("REVIEW:CONTINUE:Proceed to writing")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})

      # Now step 2 should include step 1's output
      {:next, :writer, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "Write draft"
      assert msg.content =~ "Research findings here"
    end

    test "excludes unrelated step outputs" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write independently"}
        ])

      # Execute step 1
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant("Research findings")
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      # Review: CONTINUE
      review_msg = Message.assistant("REVIEW:CONTINUE:ok")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})

      # Step 2 has no deps, shouldn't include step 1's output in CONTEXT
      {:next, :writer, msg, _state} = Plan.next(state, make_context())
      refute msg.content =~ "Research findings"
    end

    test "all steps completed → {:done, summary}" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Do research"}
        ])

      # Execute and complete step 1
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant("Research done")
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      # Review: CONTINUE
      review_msg = Message.assistant("REVIEW:CONTINUE:all done")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})

      # No more pending steps → done
      {:done, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "Research done"
    end

    test "blocked (failed deps) first time → routes to planner review" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write", deps: [1]}
        ])

      # Execute step 1 → fails
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      error = Error.new(:provider_error, "API failed")
      {:continue, state} = Plan.handle_result(state, :researcher, {:error, error})

      # Review: CONTINUE (planner says continue without fixing)
      review_msg = Message.assistant("REVIEW:CONTINUE:just continue")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})

      # Now executing: step 2 is blocked by failed step 1
      {:next, :planner, msg, state} = Plan.next(state, make_context())
      assert msg.content =~ "blocked"
      assert state.phase == :reviewing
      assert state.reviewed_blocked == true
    end

    test "blocked sets current_step to first failed blocking step" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "First task"},
          %{id: 2, agent: "writer", desc: "Second task"},
          %{id: 3, agent: "researcher", desc: "Depends on both", deps: [1, 2]}
        ])

      # Execute step 1 successfully
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done 1")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :planner, {:ok, Message.assistant("REVIEW:CONTINUE:next")})

      # Execute step 2 → fails
      {:next, :writer, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :writer, {:error, Error.new(:provider_error, "fail")})

      # Review step 2 failure: CONTINUE
      {:next, :planner, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(
          state,
          :planner,
          {:ok, Message.assistant("REVIEW:CONTINUE:keep going")}
        )

      # Now step 3 is blocked by failed step 2; current_step should be set to 2 (the blocker)
      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      assert state.current_step == 2
      assert state.reviewed_blocked == true
    end

    test "blocked after planner review → {:error, stall}" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write", deps: [1]}
        ])

      # Execute step 1 → fails
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:error, Error.new(:provider_error, "fail")})

      # Review: CONTINUE
      review_msg = Message.assistant("REVIEW:CONTINUE:just continue")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})

      # First blocked → goes to planner review
      {:next, :planner, _msg, state} = Plan.next(state, make_context())

      # Planner says CONTINUE again
      review_msg2 = Message.assistant("REVIEW:CONTINUE:try again")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg2})

      # Still blocked → stall
      {:error, %Error{type: :orchestration_error, message: msg}, _state} =
        Plan.next(state, make_context())

      assert msg =~ "stalled"
    end
  end

  # --- next/2 — reviewing phase ---

  describe "next/2 — reviewing phase" do
    test "sends review prompt to planner" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research topic"}
        ])

      # Execute step
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant("Done researching")
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      assert state.phase == :reviewing

      {:next, :planner, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "Review the result"
      assert msg.content =~ "Research topic"
    end

    test "includes step output in prompt" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research topic"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant("Detailed research output")
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      {:next, :planner, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "Detailed research output"
    end

    test "includes plan status summary" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write", deps: [1]}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant("Research done")
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      {:next, :planner, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "PLAN STATUS"
      assert msg.content =~ "completed"
      assert msg.content =~ "pending"
    end
  end

  # --- handle_result/3 — planning ---

  describe "handle_result/3 — planning" do
    test "valid plan parsed → transitions to :executing" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "Research the topic"},
          %{id: 2, agent: "writer", desc: "Write the draft", deps: [1]}
        ])

      msg = Message.assistant(content)
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, msg})

      assert state.phase == :executing
      assert length(state.plan) == 2
      assert Enum.at(state.plan, 0).assignee == :researcher
      assert Enum.at(state.plan, 1).assignee == :writer
      assert Enum.at(state.plan, 1).deps == [1]
    end

    test "empty plan → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("PLAN\nEND_PLAN")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "no steps"
    end

    test "exceeds max_plan_steps → error" do
      {:ok, state} = Plan.init(init_config(%{max_plan_steps: 2}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "Step 1"},
          %{id: 2, agent: "writer", desc: "Step 2"},
          %{id: 3, agent: "researcher", desc: "Step 3"}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "maximum is 2"
    end

    test "unknown agent in plan → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "nonexistent", desc: "Do something"}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "Unknown worker agent"
      assert err_msg =~ "nonexistent"
    end

    test "duplicate step IDs → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "First"},
          %{id: 1, agent: "writer", desc: "Second"}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "duplicate step IDs"
    end

    test "missing dependency IDs → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "Research", deps: [99]}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "unknown dependency IDs"
    end

    test "self-dependency → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "Research", deps: [1]}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "self-dependency"
    end

    test "dependency cycle → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "A", deps: [2]},
          %{id: 2, agent: "writer", desc: "B", deps: [1]}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "cycle"
    end

    test "nil/empty content → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant(nil, [])

      {:error, %Error{type: :orchestration_error}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})
    end

    test "custom parse_plan function used" do
      custom_fn = fn content, _lookup ->
        if content =~ "MY_PLAN" do
          {:ok, [%{id: 1, description: "Custom step", assignee: :researcher, deps: []}]}
        else
          {:error, Error.new(:orchestration_error, "Bad format")}
        end
      end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("MY_PLAN:do stuff")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, msg})

      assert state.phase == :executing
      assert length(state.plan) == 1
      assert hd(state.plan).description == "Custom step"
    end

    test "custom parse_plan raises → typed error" do
      custom_fn = fn _content, _lookup -> raise "parser boom" end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("some plan")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "Custom parse_plan crashed"
      assert err_msg =~ "parser boom"
    end

    test "custom parse_plan bad return shape → typed error" do
      custom_fn = fn _content, _lookup -> :wrong end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("some plan")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "invalid shape"
    end

    test "custom parse_plan returning empty list → error" do
      custom_fn = fn _content, _lookup -> {:ok, []} end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("any plan content")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "no steps"
    end

    test "custom parse_plan with malformed step shape → error" do
      custom_fn = fn _content, _lookup ->
        {:ok, [%{id: "not_an_int", description: "bad", assignee: :researcher, deps: []}]}
      end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("any plan content")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "invalid :id"
    end

    test "custom parse_plan with missing keys → error" do
      custom_fn = fn _content, _lookup ->
        {:ok, [%{id: 1}]}
      end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("any plan content")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "invalid :description"
    end

    test "custom parse_review with invalid decision shape → error" do
      custom_fn = fn _content -> {:ok, :not_a_valid_tuple} end

      state =
        init_and_plan(%{parse_review: custom_fn}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("review this")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, review_msg})

      assert err_msg =~ "invalid shape"
    end

    test "custom parse_plan with unknown assignee → error at validation" do
      custom_fn = fn _content, _lookup ->
        {:ok, [%{id: 1, description: "Do work", assignee: :nonexistent, deps: []}]}
      end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("any plan content")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "unknown worker"
      assert err_msg =~ "nonexistent"
    end

    test "custom parse_plan assigning planner as worker → error at validation" do
      custom_fn = fn _content, _lookup ->
        {:ok, [%{id: 1, description: "Do work", assignee: :planner, deps: []}]}
      end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("any plan content")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "unknown worker"
      assert err_msg =~ "planner"
    end

    test "malformed dependency IDs are rejected" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content = "PLAN\nSTEP:1:researcher:Research\nSTEP:2:writer:Write:DEP:1,abc\nEND_PLAN"
      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "Invalid dependency ID"
      assert err_msg =~ "abc"
    end

    test "missing PLAN markers → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("Here's my plan: step 1 do research step 2 write it up")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "PLAN/END_PLAN"
    end
  end

  # --- handle_result/3 — executing ---

  describe "handle_result/3 — executing" do
    test "success → stores artifact (message + content), transitions to :reviewing" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant("Here are the findings")
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      assert state.phase == :reviewing
      assert state.artifacts[1].content == "Here are the findings"
      assert state.artifacts[1].message == result_msg
      assert hd(state.plan).status == :completed
    end

    test "nil content in success → stores with nil content" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      result_msg = Message.assistant(nil, [])
      {:continue, state} = Plan.handle_result(state, :researcher, {:ok, result_msg})

      assert state.phase == :reviewing
      assert state.artifacts[1].content == nil
      assert state.artifacts[1].message == result_msg
    end

    test "error → marks failed, transitions to :reviewing" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      error = Error.new(:provider_error, "API failed")
      {:continue, state} = Plan.handle_result(state, :researcher, {:error, error})

      assert state.phase == :reviewing
      assert hd(state.plan).status == :failed
      assert state.failure_count == 1
    end
  end

  # --- handle_result/3 — reviewing ---

  describe "handle_result/3 — reviewing" do
    test "COMPLETE → {:done, summary}" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      # Execute + review
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("findings")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:COMPLETE:All research is done")

      {:done, msg, _state} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert msg.content == "All research is done"
    end

    test "COMPLETE with empty summary uses artifact summary" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("findings")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:COMPLETE:")

      {:done, msg, _state} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert msg.content =~ "findings"
    end

    test "CONTINUE → phase :executing, reviewed_blocked reset" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write", deps: [1]}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:CONTINUE:move to next step")

      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert state.phase == :executing
      assert state.reviewed_blocked == false
    end

    test "RETRY with retries left → reset step, :executing" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:error, Error.new(:provider_error, "fail")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:RETRY:try again")

      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert state.phase == :executing

      step = hd(state.plan)
      assert step.status == :pending
      assert step.retry_count == 1
    end

    test "RETRY exhausted → {:error, stall}" do
      state =
        init_and_plan(%{max_retries_per_step: 0}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:error, Error.new(:provider_error, "fail")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:RETRY:try again")

      {:error, %Error{type: :orchestration_error, message: msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, review_msg})

      assert msg =~ "exhausted retries"
    end

    test "REASSIGN valid agent → change assignee, reset retry, :executing" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:error, Error.new(:provider_error, "fail")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:REASSIGN:writer:writer can do it better")

      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert state.phase == :executing

      step = hd(state.plan)
      assert step.assignee == :writer
      assert step.status == :pending
      assert step.retry_count == 0
    end

    test "REASSIGN unknown agent → {:error}" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:REASSIGN:nonexistent:try them")

      {:error, %Error{type: :orchestration_error, message: msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, review_msg})

      assert msg =~ "unknown agent"
    end

    test "REPLAN with replans left → phase :planning, clear plan" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("bad result")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:REPLAN:need different approach")

      {:continue, state, _events} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert state.phase == :planning
      assert state.plan == []
      assert state.replan_count == 1
    end

    test "REPLAN exhausted → {:error, replan limit}" do
      state =
        init_and_plan(%{max_replans: 0}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:REPLAN:try again")

      {:error, %Error{type: :orchestration_error, message: msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, review_msg})

      assert msg =~ "Replan limit"
    end

    test "custom parse_review function used" do
      custom_fn = fn content ->
        if content =~ "DONE" do
          {:ok, {:complete, "Custom completion"}}
        else
          {:error, Error.new(:orchestration_error, "Unknown")}
        end
      end

      state =
        init_and_plan(%{parse_review: custom_fn}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("DONE")

      {:done, msg, _state} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert msg.content == "Custom completion"
    end

    test "custom parse_review raises → typed error" do
      custom_fn = fn _content -> raise "review boom" end

      state =
        init_and_plan(%{parse_review: custom_fn}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("review this")

      {:error, %Error{type: :orchestration_error, message: msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, review_msg})

      assert msg =~ "Custom parse_review crashed"
      assert msg =~ "review boom"
    end

    test "custom parse_review bad return shape → typed error" do
      custom_fn = fn _content -> :invalid end

      state =
        init_and_plan(%{parse_review: custom_fn}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("review this")

      {:error, %Error{type: :orchestration_error, message: msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, review_msg})

      assert msg =~ "invalid shape"
    end
  end

  # --- handle_result/3 — error propagation ---

  describe "handle_result/3 — error propagation" do
    test "planner error in planning → propagated" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      error = Error.new(:provider_error, "planner failed")

      {:error, ^error, _state} = Plan.handle_result(state, :planner, {:error, error})
    end

    test "planner error in reviewing → propagated" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      error = Error.new(:provider_error, "planner crashed during review")

      {:error, ^error, _state} = Plan.handle_result(state, :planner, {:error, error})
    end

    test "worker error in executing → marks step failed, to review" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())
      error = Error.new(:provider_error, "worker failed")
      {:continue, state} = Plan.handle_result(state, :researcher, {:error, error})

      assert state.phase == :reviewing
      assert hd(state.plan).status == :failed
    end
  end

  # --- Plan validation ---

  describe "plan validation" do
    test "valid DAG passes" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "A"},
          %{id: 2, agent: "writer", desc: "B", deps: [1]},
          %{id: 3, agent: "researcher", desc: "C", deps: [1, 2]}
        ])

      assert state.phase == :executing
      assert length(state.plan) == 3
    end

    test "3-node cycle detected" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "A", deps: [3]},
          %{id: 2, agent: "writer", desc: "B", deps: [1]},
          %{id: 3, agent: "researcher", desc: "C", deps: [2]}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "cycle"
    end

    test "mixed valid + cycle rejected" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        plan_response([
          %{id: 1, agent: "researcher", desc: "Valid standalone"},
          %{id: 2, agent: "writer", desc: "Cycle A", deps: [3]},
          %{id: 3, agent: "researcher", desc: "Cycle B", deps: [2]}
        ])

      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "cycle"
    end
  end

  # --- Context slicing ---

  describe "context slicing" do
    test "step with deps gets dependency outputs" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write", deps: [1]}
        ])

      # Complete step 1
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("research output")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("REVIEW:CONTINUE:next")
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, review_msg})

      # Step 2 should reference step 1
      {:next, :writer, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "Result from step 1"
      assert msg.content =~ "research output"
    end

    test "step without deps gets only task description" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Independent research"}
        ])

      {:next, :researcher, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "Independent research"
      refute msg.content =~ "CONTEXT"
    end

    test "step with multiple deps gets all dep outputs" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research A"},
          %{id: 2, agent: "researcher", desc: "Research B"},
          %{id: 3, agent: "writer", desc: "Combine", deps: [1, 2]}
        ])

      # Complete step 1
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("output A")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :planner, {:ok, Message.assistant("REVIEW:CONTINUE:next")})

      # Complete step 2
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("output B")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :planner, {:ok, Message.assistant("REVIEW:CONTINUE:next")})

      # Step 3 should have both deps
      {:next, :writer, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "output A"
      assert msg.content =~ "output B"
    end
  end

  # --- Parser safety ---

  describe "parser safety" do
    test "parse_plan throw → orchestration_error" do
      custom_fn = fn _content, _lookup -> throw(:oops) end

      {:ok, state} = Plan.init(init_config(%{parse_plan: custom_fn}))
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      msg = Message.assistant("plan content")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "Custom parse_plan crashed"
      assert err_msg =~ "throw"
    end

    test "parse_review throw → orchestration_error" do
      custom_fn = fn _content -> throw(:oops) end

      state =
        init_and_plan(%{parse_review: custom_fn}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())
      review_msg = Message.assistant("review this")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, review_msg})

      assert err_msg =~ "Custom parse_review crashed"
    end
  end

  # --- Determinism ---

  describe "determinism" do
    test "worker list in prompt is alphabetically sorted" do
      {:ok, state} =
        Plan.init(%{
          agent_names: [:planner, :zoe, :alice, :bob],
          planner_agent: :planner
        })

      {:next, :planner, msg, _state} = Plan.next(state, make_context())
      assert msg.content =~ "alice, bob, zoe"
    end
  end

  # --- CONTINUE after failed step → blocked graph handling ---

  describe "CONTINUE after failed step → blocked graph" do
    test "CONTINUE into blocked graph → planner consulted → REPLAN → success path" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"},
          %{id: 2, agent: "writer", desc: "Write", deps: [1]}
        ])

      # Step 1 fails
      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:error, Error.new(:provider_error, "fail")})

      # Review: CONTINUE (without fixing)
      {:next, :planner, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(
          state,
          :planner,
          {:ok, Message.assistant("REVIEW:CONTINUE:keep going")}
        )

      # Executing: blocked → routes to planner with blocked context
      assert state.phase == :executing
      {:next, :planner, msg, state} = Plan.next(state, make_context())
      assert msg.content =~ "blocked"
      assert state.phase == :reviewing
      assert state.reviewed_blocked == true

      # Planner decides to REPLAN
      {:continue, state, _events} =
        Plan.handle_result(
          state,
          :planner,
          {:ok, Message.assistant("REVIEW:REPLAN:new approach")}
        )

      assert state.phase == :planning
      assert state.replan_count == 1
    end
  end

  # --- Edge cases in plan parsing ---

  describe "plan parsing edge cases" do
    test "description with colons is preserved" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      # Description contains colons but no DEP marker
      content = "PLAN\nSTEP:1:researcher:Research this: the important topic: details\nEND_PLAN"
      msg = Message.assistant(content)
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, msg})

      step = hd(state.plan)
      assert step.description == "Research this: the important topic: details"
    end

    test "description with colons and DEP marker" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        "PLAN\nSTEP:1:researcher:First step\nSTEP:2:writer:Write about: topics:DEP:1\nEND_PLAN"

      msg = Message.assistant(content)
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, msg})

      step2 = Enum.at(state.plan, 1)
      assert step2.description == "Write about: topics"
      assert step2.deps == [1]
    end

    test "plan with extra whitespace and blank lines" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content =
        "Here's my plan:\n\n  PLAN  \n\n  STEP:1:researcher:Do research  \n\n  END_PLAN  \n\nLet me know!"

      msg = Message.assistant(content)
      {:continue, state} = Plan.handle_result(state, :planner, {:ok, msg})

      assert length(state.plan) == 1
      assert hd(state.plan).description == "Do research"
    end

    test "review directive embedded in prose" do
      state =
        init_and_plan(%{}, [
          %{id: 1, agent: "researcher", desc: "Research"}
        ])

      {:next, :researcher, _msg, state} = Plan.next(state, make_context())

      {:continue, state} =
        Plan.handle_result(state, :researcher, {:ok, Message.assistant("done")})

      {:next, :planner, _msg, state} = Plan.next(state, make_context())

      # Review directive is on its own line but surrounded by prose
      review_msg =
        Message.assistant(
          "I've reviewed the output.\nREVIEW:COMPLETE:Looks great\nThat's my assessment."
        )

      {:done, msg, _state} = Plan.handle_result(state, :planner, {:ok, review_msg})
      assert msg.content == "Looks great"
    end

    test "invalid step ID (non-numeric) → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content = "PLAN\nSTEP:abc:researcher:Research\nEND_PLAN"
      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "Invalid step ID"
    end

    test "step ID zero → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content = "PLAN\nSTEP:0:researcher:Research\nEND_PLAN"
      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "Invalid step ID"
    end

    test "empty step description → error" do
      {:ok, state} = Plan.init(init_config())
      {:next, :planner, _prompt, state} = Plan.next(state, make_context())

      content = "PLAN\nSTEP:1:researcher:  \nEND_PLAN"
      msg = Message.assistant(content)

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Plan.handle_result(state, :planner, {:ok, msg})

      assert err_msg =~ "empty description"
    end
  end
end
