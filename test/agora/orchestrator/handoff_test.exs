defmodule Agora.Orchestrator.HandoffTest do
  use ExUnit.Case, async: true

  alias Agora.{Error, Message}
  alias Agora.Orchestrator.Handoff

  # --- Test helpers ---

  defp init_config(overrides \\ %{}) do
    base = %{
      agent_names: [:agent_a, :agent_b, :agent_c],
      initial_agent: :agent_a
    }

    Map.merge(base, overrides)
  end

  defp init!(overrides \\ %{}) do
    {:ok, state} = Handoff.init(init_config(overrides))
    state
  end

  defp context(input) do
    %{original_input: Message.user(input), history: []}
  end

  defp assistant_msg(content, opts \\ []) do
    Message.new(:assistant, content, opts)
  end

  defp handoff_msg(target, message, content \\ "routing") do
    Message.new(:assistant, content,
      metadata: %{handoff: %{target: target, message: message}}
    )
  end

  # --- Tests ---

  describe "init/1" do
    test "valid config produces correct initial state" do
      {:ok, state} = Handoff.init(init_config())

      assert state.initial_agent == :agent_a
      assert state.current_agent == :agent_a
      assert state.handoff_history == [:agent_a]
      assert state.hop_count == 0
      assert state.handoff_message == nil
      assert state.max_hops == 10
      assert state.no_repeat_window == nil
      assert state.allowed_targets == nil
      assert state.parse_fn == nil
    end

    test "missing :initial_agent returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(%{agent_names: [:a, :b]})

      assert msg =~ "requires :initial_agent"
    end

    test ":initial_agent not in agent_names returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{initial_agent: :unknown}))

      assert msg =~ ":initial_agent"
      assert msg =~ ":unknown"
    end

    test ":initial_agent must be an atom" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{initial_agent: "agent_a"}))

      assert msg =~ "must be an atom"
    end

    test "builds agent_lookup from ALL agents" do
      {:ok, state} = Handoff.init(init_config())

      assert Map.has_key?(state.agent_lookup, "agent_a")
      assert Map.has_key?(state.agent_lookup, "agent_b")
      assert Map.has_key?(state.agent_lookup, "agent_c")
      assert map_size(state.agent_lookup) == 3
    end

    test "agents are sorted alphabetically" do
      {:ok, state} =
        Handoff.init(init_config(%{
          agent_names: [:zebra, :alpha, :middle],
          initial_agent: :alpha
        }))

      assert state.agents == [:alpha, :middle, :zebra]
    end

    test "default max_hops is 10" do
      {:ok, state} = Handoff.init(init_config())
      assert state.max_hops == 10
    end

    test "custom max_hops respected" do
      {:ok, state} = Handoff.init(init_config(%{max_hops: 5}))
      assert state.max_hops == 5
    end

    test "invalid max_hops 0 returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{max_hops: 0}))

      assert msg =~ ":max_hops must be a positive integer"
    end

    test "invalid max_hops negative returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{max_hops: -1}))

      assert msg =~ ":max_hops must be a positive integer"
    end

    test "invalid max_hops non-integer returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{max_hops: "ten"}))

      assert msg =~ ":max_hops must be a positive integer"
    end

    test "invalid max_hops float returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{max_hops: 5.0}))

      assert msg =~ ":max_hops must be a positive integer"
    end

    test "default no_repeat_window is nil" do
      {:ok, state} = Handoff.init(init_config())
      assert state.no_repeat_window == nil
    end

    test "custom no_repeat_window respected" do
      {:ok, state} = Handoff.init(init_config(%{no_repeat_window: 3}))
      assert state.no_repeat_window == 3
    end

    test "invalid no_repeat_window 0 returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{no_repeat_window: 0}))

      assert msg =~ ":no_repeat_window must be a positive integer"
    end

    test "invalid no_repeat_window negative returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{no_repeat_window: -1}))

      assert msg =~ ":no_repeat_window must be a positive integer"
    end

    test "invalid no_repeat_window non-integer returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{no_repeat_window: "two"}))

      assert msg =~ ":no_repeat_window must be a positive integer"
    end

    test "default allowed_handoff_targets is nil" do
      {:ok, state} = Handoff.init(init_config())
      assert state.allowed_targets == nil
    end

    test "valid allowed_handoff_targets accepted" do
      targets = %{agent_a: [:agent_b], agent_b: [:agent_a, :agent_c]}
      {:ok, state} = Handoff.init(init_config(%{allowed_handoff_targets: targets}))
      assert state.allowed_targets == targets
    end

    test "unknown agent key in allowed_handoff_targets returns error" do
      targets = %{unknown_agent: [:agent_b]}

      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{allowed_handoff_targets: targets}))

      assert msg =~ "Unknown agent"
      assert msg =~ "keys"
    end

    test "unknown agent value in allowed_handoff_targets returns error" do
      targets = %{agent_a: [:unknown_target]}

      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{allowed_handoff_targets: targets}))

      assert msg =~ "Unknown agent"
      assert msg =~ "values"
    end

    test "custom parse_handoff (2-arity) accepted" do
      parse_fn = fn _content, _lookup -> :no_handoff end
      {:ok, state} = Handoff.init(init_config(%{parse_handoff: parse_fn}))
      assert state.parse_fn != nil
    end

    test "invalid parse_handoff arity (1-arity) returns error" do
      parse_fn = fn _content -> :no_handoff end

      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{parse_handoff: parse_fn}))

      assert msg =~ ":parse_handoff must be a 2-arity function"
    end

    test "non-function parse_handoff returns error" do
      {:error, %Error{type: :orchestration_error, message: msg}} =
        Handoff.init(init_config(%{parse_handoff: "not a function"}))

      assert msg =~ ":parse_handoff must be a 2-arity function or nil"
    end
  end

  describe "next/2" do
    test "first turn sends original_input to initial_agent" do
      state = init!()
      ctx = context("Hello world")

      {:next, agent, input, _state} = Handoff.next(state, ctx)

      assert agent == :agent_a
      assert input == ctx.original_input
    end

    test "after handoff sends handoff_message as Message.user to target agent" do
      state = %{init!() | current_agent: :agent_b, handoff_message: "handle this"}
      ctx = context("original")

      {:next, agent, input, _state} = Handoff.next(state, ctx)

      assert agent == :agent_b
      assert input.role == :user
      assert input.content == "handle this"
    end
  end

  describe "handle_result/3 — handoff via metadata" do
    test "string target via metadata triggers handoff" do
      state = init!()
      msg = handoff_msg("agent_b", "please handle")

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.current_agent == :agent_b
      assert new_state.handoff_message == "please handle"
      assert new_state.hop_count == 1
      assert new_state.handoff_history == [:agent_a, :agent_b]
    end

    test "atom target in metadata triggers handoff" do
      state = init!()

      msg =
        Message.new(:assistant, "routing",
          metadata: %{handoff: %{target: :agent_b, message: "context"}}
        )

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.current_agent == :agent_b
      assert new_state.handoff_message == "context"
    end

    test "missing :message key uses response content" do
      state = init!()

      msg =
        Message.new(:assistant, "response content",
          metadata: %{handoff: %{target: "agent_b"}}
        )

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.handoff_message == "response content"
    end

    test "nil content with no :message key normalizes to empty string" do
      state = init!()

      msg =
        Message.new(:assistant, nil,
          metadata: %{handoff: %{target: "agent_b"}}
        )

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.handoff_message == ""
    end

    test "unknown target in metadata returns error" do
      state = init!()
      msg = handoff_msg("unknown_agent", "help")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Unknown handoff target"
      assert err_msg =~ "unknown_agent"
    end

    test "metadata takes priority over HANDOFF directive in content" do
      state = init!()

      # Content has directive to agent_c, but metadata says agent_b
      msg =
        Message.new(:assistant, "HANDOFF:agent_c:go to c",
          metadata: %{handoff: %{target: "agent_b", message: "go to b"}}
        )

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      # Metadata wins
      assert new_state.current_agent == :agent_b
      assert new_state.handoff_message == "go to b"
    end

    test "malformed metadata (not a map) returns error without fallback" do
      state = init!()

      msg =
        Message.new(:assistant, "HANDOFF:agent_b:fallback",
          metadata: %{handoff: "just a string"}
        )

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Malformed handoff metadata"
    end

    test "malformed metadata (missing :target) returns error without fallback" do
      state = init!()

      msg =
        Message.new(:assistant, "HANDOFF:agent_b:fallback",
          metadata: %{handoff: %{message: "no target"}}
        )

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "missing :target"
    end

    test "malformed metadata (:target is integer) returns error without fallback" do
      state = init!()

      msg =
        Message.new(:assistant, "HANDOFF:agent_b:fallback",
          metadata: %{handoff: %{target: 42}}
        )

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Malformed handoff metadata"
    end
  end

  describe "handle_result/3 — handoff via directive" do
    test "HANDOFF:agent:message parsed correctly" do
      state = init!()
      msg = assistant_msg("HANDOFF:agent_b:Please help with this")

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.current_agent == :agent_b
      assert new_state.handoff_message == "Please help with this"
    end

    test "unknown target in directive returns error" do
      state = init!()
      msg = assistant_msg("HANDOFF:nonexistent:help")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Unknown handoff target"
      assert err_msg =~ "nonexistent"
    end

    test "no directive and no metadata results in done" do
      state = init!()
      msg = assistant_msg("I've completed the task")

      {:done, result_msg, _state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert result_msg.content == "I've completed the task"
    end

    test "nil content results in done" do
      state = init!()
      msg = assistant_msg(nil)

      {:done, result_msg, _state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert result_msg.content == nil
    end

    test "multiline content with HANDOFF on first line" do
      state = init!()
      msg = assistant_msg("HANDOFF:agent_b:handle this\nwith more context")

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.current_agent == :agent_b
      assert new_state.handoff_message == "handle this\nwith more context"
    end
  end

  describe "handle_result/3 — self-handoff" do
    test "self-handoff with nil allowed_targets returns error" do
      state = init!()
      msg = handoff_msg("agent_a", "back to myself")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Self-handoff not allowed"
    end

    test "self-handoff explicitly in allowed_targets map is allowed" do
      state = init!(%{allowed_handoff_targets: %{agent_a: [:agent_a, :agent_b]}})
      msg = handoff_msg("agent_a", "retry myself")

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.current_agent == :agent_a
    end

    test "self-handoff not in allowed_targets map returns error" do
      state = init!(%{allowed_handoff_targets: %{agent_a: [:agent_b]}})
      msg = handoff_msg("agent_a", "try myself")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "not allowed by policy"
    end
  end

  describe "handle_result/3 — safety checks" do
    test "max hops exceeded returns error with metadata" do
      state = %{init!(%{max_hops: 2}) | hop_count: 2}
      msg = handoff_msg("agent_b", "too many hops")

      {:error, %Error{type: :orchestration_error, message: err_msg, metadata: meta}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Max hops"
      assert meta.hop_count == 2
      assert meta.max_hops == 2
    end

    test "allowed target passes validation" do
      state = init!(%{allowed_handoff_targets: %{agent_a: [:agent_b, :agent_c]}})
      msg = handoff_msg("agent_b", "go")

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.current_agent == :agent_b
    end

    test "disallowed target returns error" do
      state = init!(%{allowed_handoff_targets: %{agent_a: [:agent_b]}})
      msg = handoff_msg("agent_c", "not allowed")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "not allowed by policy"
    end

    test "agent not in allowed_targets keys (fail-closed) returns error" do
      # agent_a can hand off, but agent_b is not in the keys at all
      state = %{
        init!(%{allowed_handoff_targets: %{agent_a: [:agent_b]}})
        | current_agent: :agent_b
      }

      msg = handoff_msg("agent_c", "try to hand off")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_b, {:ok, msg})

      assert err_msg =~ "not permitted to hand off"
    end

    test "no_repeat_window blocks recent target (A→B→A with window=2)" do
      state = %{
        init!(%{no_repeat_window: 2})
        | current_agent: :agent_b,
          handoff_history: [:agent_a, :agent_b],
          hop_count: 1
      }

      msg = handoff_msg("agent_a", "back to a")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_b, {:ok, msg})

      assert err_msg =~ "no_repeat_window"
    end

    test "no_repeat_window=1 blocks immediate bounce (A→B→B)" do
      state = %{
        init!(%{no_repeat_window: 1})
        | current_agent: :agent_b,
          handoff_history: [:agent_a, :agent_b],
          hop_count: 1
      }

      msg = handoff_msg("agent_b", "back to b")

      # Self-handoff is checked first (blocked by default with nil allowed_targets)
      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_b, {:ok, msg})

      assert err_msg =~ "Self-handoff not allowed"
    end

    test "no_repeat_window nil allows repeats freely" do
      state = %{
        init!()
        | current_agent: :agent_b,
          handoff_history: [:agent_a, :agent_b],
          hop_count: 1
      }

      msg = handoff_msg("agent_a", "back to a")

      {:continue, new_state} = Handoff.handle_result(state, :agent_b, {:ok, msg})

      assert new_state.current_agent == :agent_a
    end

    test "validation order: self-handoff checked before max_hops" do
      state = %{init!(%{max_hops: 1}) | hop_count: 1}
      msg = handoff_msg("agent_a", "self and over limit")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      # Self-handoff error fires first, not max_hops
      assert err_msg =~ "Self-handoff not allowed"
    end
  end

  describe "handle_result/3 — error propagation" do
    test "agent error propagated as-is" do
      state = init!()
      error = Error.new(:provider_error, "API failed")

      {:error, ^error, _state} = Handoff.handle_result(state, :agent_a, {:error, error})
    end
  end

  describe "custom parse_handoff" do
    test "custom parser used when no metadata present" do
      parse_fn = fn content, _lookup ->
        if String.contains?(content, "ROUTE:") do
          [_, target, msg] = String.split(content, ":", parts: 3)
          {:handoff, String.to_existing_atom(target), msg}
        else
          :no_handoff
        end
      end

      state = init!(%{parse_handoff: parse_fn})
      msg = assistant_msg("ROUTE:agent_b:custom format")

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert new_state.current_agent == :agent_b
      assert new_state.handoff_message == "custom format"
    end

    test "custom parser crash (raise) returns orchestration_error" do
      parse_fn = fn _content, _lookup -> raise "boom" end
      state = init!(%{parse_handoff: parse_fn})
      msg = assistant_msg("trigger crash")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Custom parse_handoff crashed"
      assert err_msg =~ "boom"
    end

    test "custom parser crash (throw) returns orchestration_error" do
      parse_fn = fn _content, _lookup -> throw(:oops) end
      state = init!(%{parse_handoff: parse_fn})
      msg = assistant_msg("trigger throw")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "Custom parse_handoff crashed"
      assert err_msg =~ "throw"
    end

    test "custom parser bad return shape returns orchestration_error" do
      parse_fn = fn _content, _lookup -> :bad_return end
      state = init!(%{parse_handoff: parse_fn})
      msg = assistant_msg("trigger bad return")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "invalid shape"
    end

    test "custom parser {:handoff, target, non_binary_message} returns error" do
      parse_fn = fn _content, _lookup -> {:handoff, :agent_b, 42} end
      state = init!(%{parse_handoff: parse_fn})
      msg = assistant_msg("trigger non-binary")

      {:error, %Error{type: :orchestration_error, message: err_msg}, _state} =
        Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert err_msg =~ "non-binary message"
    end

    test "custom parser :no_handoff results in done" do
      parse_fn = fn _content, _lookup -> :no_handoff end
      state = init!(%{parse_handoff: parse_fn})
      msg = assistant_msg("task complete")

      {:done, result_msg, _state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert result_msg.content == "task complete"
    end

    test "custom parser + directive content present + parser returns :no_handoff results in done (no fallback)" do
      parse_fn = fn _content, _lookup -> :no_handoff end
      state = init!(%{parse_handoff: parse_fn})
      # Content has a valid HANDOFF directive, but custom parser says no_handoff
      msg = assistant_msg("HANDOFF:agent_b:this should be ignored by custom parser")

      {:done, result_msg, _state} = Handoff.handle_result(state, :agent_a, {:ok, msg})

      assert result_msg.content =~ "HANDOFF:agent_b"
    end
  end

  describe "state tracking" do
    test "hop_count increments on each handoff" do
      state = init!()
      msg = handoff_msg("agent_b", "go")

      {:continue, state2} = Handoff.handle_result(state, :agent_a, {:ok, msg})
      assert state2.hop_count == 1

      msg2 = handoff_msg("agent_c", "continue")

      {:continue, state3} = Handoff.handle_result(state2, :agent_b, {:ok, msg2})
      assert state3.hop_count == 2
    end

    test "handoff_history appends target on each handoff" do
      state = init!()
      msg = handoff_msg("agent_b", "go")

      {:continue, state2} = Handoff.handle_result(state, :agent_a, {:ok, msg})
      assert state2.handoff_history == [:agent_a, :agent_b]

      msg2 = handoff_msg("agent_c", "continue")

      {:continue, state3} = Handoff.handle_result(state2, :agent_b, {:ok, msg2})
      assert state3.handoff_history == [:agent_a, :agent_b, :agent_c]
    end

    test "handoff_history includes initial_agent as first entry" do
      {:ok, state} = Handoff.init(init_config())
      assert hd(state.handoff_history) == :agent_a
    end

    test "current_agent updates to target after handoff" do
      state = init!()
      msg = handoff_msg("agent_b", "go")

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})
      assert new_state.current_agent == :agent_b
    end

    test "handoff_message updates to normalized message" do
      state = init!()

      # nil message normalizes to ""
      msg =
        Message.new(:assistant, nil,
          metadata: %{handoff: %{target: "agent_b", message: nil}}
        )

      {:continue, new_state} = Handoff.handle_result(state, :agent_a, {:ok, msg})
      assert new_state.handoff_message == ""
    end
  end
end
