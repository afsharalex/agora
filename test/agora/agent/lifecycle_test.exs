defmodule Agora.Agent.LifecycleTest do
  use ExUnit.Case, async: true

  alias Agora.Agent.Lifecycle
  alias Agora.Agent.Lifecycle.StateConfig

  describe "new!/1 valid configurations" do
    test "creates lifecycle with minimal config" do
      lc =
        Lifecycle.new!(
          initial_state: :ready,
          states: %{ready: %StateConfig{}}
        )

      assert lc.initial_state == :ready
      assert Map.has_key?(lc.states, :ready)
      assert lc.transitions == []
    end

    test "creates lifecycle with multiple states and transitions" do
      lc =
        Lifecycle.new!(
          initial_state: :collecting,
          states: %{
            collecting: %StateConfig{instructions: "Collect info"},
            processing: %StateConfig{instructions: "Process info"}
          },
          transitions: [
            %{from: :collecting, to: :processing, trigger: {:tool_call, "submit"}, guard: nil}
          ]
        )

      assert lc.initial_state == :collecting
      assert length(lc.transitions) == 1
    end

    test "creates lifecycle with on_enter and on_exit callbacks" do
      lc =
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{from: :a, to: :b, trigger: {:message_match, &is_binary(&1.content)}, guard: nil}
          ],
          on_enter: %{a: fn _from, _to -> :ok end, b: fn _from, _to -> :ok end},
          on_exit: %{a: fn _from, _to -> :ok end}
        )

      assert map_size(lc.on_enter) == 2
      assert map_size(lc.on_exit) == 1
    end

    test "allows state_timeout trigger" do
      lc =
        Lifecycle.new!(
          initial_state: :waiting,
          states: %{waiting: %StateConfig{}, timeout: %StateConfig{}},
          transitions: [
            %{from: :waiting, to: :timeout, trigger: {:state_timeout, 5000}, guard: nil}
          ]
        )

      assert length(lc.transitions) == 1
    end

    test "allows tool_result trigger with predicate" do
      lc =
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{
              from: :a,
              to: :b,
              trigger: {:tool_result, "search", fn result -> result.content == "found" end},
              guard: nil
            }
          ]
        )

      assert length(lc.transitions) == 1
    end

    test "allows multiple transitions from same state with different triggers" do
      lc =
        Lifecycle.new!(
          initial_state: :start,
          states: %{start: %StateConfig{}, a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{from: :start, to: :a, trigger: {:tool_call, "go_a"}, guard: nil},
            %{from: :start, to: :b, trigger: {:tool_call, "go_b"}, guard: nil}
          ]
        )

      assert length(lc.transitions) == 2
    end

    test "allows guard function on transitions" do
      lc =
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{
              from: :a,
              to: :b,
              trigger: {:tool_call, "submit"},
              guard: fn ctx -> ctx.outcome != nil end
            }
          ]
        )

      assert length(lc.transitions) == 1
    end
  end

  describe "new!/1 validation errors" do
    test "raises when no states defined" do
      assert_raise ArgumentError, ~r/at least one state/, fn ->
        Lifecycle.new!(initial_state: :a, states: %{})
      end
    end

    test "raises when initial_state is nil" do
      assert_raise ArgumentError, ~r/initial_state is required/, fn ->
        Lifecycle.new!(initial_state: nil, states: %{a: %StateConfig{}})
      end
    end

    test "raises when initial_state not in states" do
      assert_raise ArgumentError, ~r/initial_state :missing not found/, fn ->
        Lifecycle.new!(initial_state: :missing, states: %{a: %StateConfig{}})
      end
    end

    test "raises when transition :from references unknown state" do
      assert_raise ArgumentError, ~r/transition :from :unknown not found/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{from: :unknown, to: :b, trigger: {:tool_call, "x"}, guard: nil}
          ]
        )
      end
    end

    test "raises when transition :to references unknown state" do
      assert_raise ArgumentError, ~r/transition :to :unknown not found/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{from: :a, to: :unknown, trigger: {:tool_call, "x"}, guard: nil}
          ]
        )
      end
    end

    test "raises when more than one state_timeout per source state" do
      assert_raise ArgumentError, ~r/more than one :state_timeout/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}, c: %StateConfig{}},
          transitions: [
            %{from: :a, to: :b, trigger: {:state_timeout, 5000}, guard: nil},
            %{from: :a, to: :c, trigger: {:state_timeout, 10_000}, guard: nil}
          ]
        )
      end
    end

    test "raises on invalid trigger format" do
      assert_raise ArgumentError, ~r/invalid transition trigger/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{from: :a, to: :b, trigger: :bad_trigger, guard: nil}
          ]
        )
      end
    end

    test "raises when on_enter references unknown state" do
      assert_raise ArgumentError, ~r/on_enter callback for :unknown/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}},
          on_enter: %{unknown: fn _from, _to -> :ok end}
        )
      end
    end

    test "raises when on_exit references unknown state" do
      assert_raise ArgumentError, ~r/on_exit callback for :unknown/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}},
          on_exit: %{unknown: fn _from, _to -> :ok end}
        )
      end
    end

    test "raises when on_enter callback is not 2-arity" do
      assert_raise ArgumentError, ~r/on_enter callback.*must be a 2-arity function/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}},
          on_enter: %{a: fn _state -> :ok end}
        )
      end
    end

    test "raises when on_exit callback is not 2-arity" do
      assert_raise ArgumentError, ~r/on_exit callback.*must be a 2-arity function/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}},
          on_exit: %{a: "not a function"}
        )
      end
    end

    test "raises when guard is not nil or 1-arity function" do
      assert_raise ArgumentError, ~r/guard must be nil or a 1-arity function/, fn ->
        Lifecycle.new!(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{from: :a, to: :b, trigger: {:tool_call, "x"}, guard: fn _a, _b -> true end}
          ]
        )
      end
    end
  end

  describe "validate/1" do
    test "returns {:ok, lifecycle} for valid struct" do
      lc =
        Lifecycle.new!(
          initial_state: :ready,
          states: %{ready: %StateConfig{}}
        )

      assert {:ok, ^lc} = Lifecycle.validate(lc)
    end

    test "returns {:error, reason} for invalid struct" do
      invalid = %Lifecycle{initial_state: :missing, states: %{a: %StateConfig{}}}
      assert {:error, reason} = Lifecycle.validate(invalid)
      assert reason =~ "initial_state :missing not found"
    end

    test "returns {:error, reason} for empty states" do
      invalid = %Lifecycle{initial_state: :a, states: %{}}
      assert {:error, reason} = Lifecycle.validate(invalid)
      assert reason =~ "at least one state"
    end

    test "returns {:error, reason} for malformed transition maps" do
      # Transition missing :from/:to keys causes FunctionClauseError, not ArgumentError
      invalid = %Lifecycle{
        initial_state: :a,
        states: %{a: %StateConfig{}, b: %StateConfig{}},
        transitions: [%{trigger: {:tool_call, "x"}}]
      }

      assert {:error, _reason} = Lifecycle.validate(invalid)
    end

    test "returns {:error, reason} for nil input" do
      assert {:error, reason} = Lifecycle.validate(nil)
      assert reason =~ "expected %Agora.Agent.Lifecycle{}"
    end

    test "returns {:error, reason} for non-struct input" do
      assert {:error, reason} = Lifecycle.validate(%{initial_state: :a})
      assert reason =~ "expected %Agora.Agent.Lifecycle{}"
    end
  end

  describe "StateConfig" do
    test "defaults all fields to nil" do
      sc = %StateConfig{}
      assert sc.instructions == nil
      assert sc.tools == nil
      assert sc.middleware == nil
      assert sc.max_iterations == nil
      assert sc.provider_opts == nil
    end

    test "accepts all overlay fields" do
      sc = %StateConfig{
        instructions: "Be helpful",
        tools: [:some_tool],
        middleware: [:some_middleware],
        max_iterations: 5,
        provider_opts: [api_key: "test"]
      }

      assert sc.instructions == "Be helpful"
      assert sc.tools == [:some_tool]
      assert sc.max_iterations == 5
    end
  end

  describe "AgentConfig :lifecycle field" do
    test "defaults to nil" do
      config = Agora.AgentConfig.new!(provider: :echo, model: "echo")
      assert config.lifecycle == nil
    end

    test "accepts Lifecycle struct" do
      lc =
        Lifecycle.new!(
          initial_state: :ready,
          states: %{ready: %StateConfig{}}
        )

      config = Agora.AgentConfig.new!(provider: :echo, model: "echo", lifecycle: lc)
      assert config.lifecycle == lc
    end
  end
end
