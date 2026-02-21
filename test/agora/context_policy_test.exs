defmodule Agora.ContextPolicyTest do
  use ExUnit.Case, async: true

  alias Agora.{ContextPolicy, Message}

  defp make_messages(specs) do
    specs
    |> Enum.with_index()
    |> Enum.map(fn {spec, _i} ->
      case spec do
        {:system, text} ->
          Message.system(text)

        {:user, text} ->
          Message.user(text)

        {:assistant, text} ->
          Message.assistant(text)

        {:assistant_tc, text, tool_calls} ->
          Message.new(:assistant, text, tool_calls: tool_calls)

        {:tool, text} ->
          Message.new(:tool, text,
            tool_results: [%Agora.ToolResult{tool_call_id: "tc1", name: "test", content: text}]
          )
      end
    end)
  end

  defp fake_tool_call do
    %Agora.ToolCall{id: "tc1", name: "test", arguments: %{}}
  end

  describe "new!/1" do
    test "creates a :none policy" do
      policy = ContextPolicy.new!(strategy: :none)
      assert policy.strategy == :none
    end

    test "creates a :sliding_window policy" do
      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 10)
      assert policy.strategy == :sliding_window
      assert Keyword.get(policy.opts, :window_size) == 10
    end

    test "creates a :head_tail policy" do
      policy = ContextPolicy.new!(strategy: :head_tail, head: 1, tail: 5)
      assert policy.strategy == :head_tail
    end

    test "creates a :summary policy with summarize_fn" do
      policy = ContextPolicy.new!(strategy: :summary, summarize_fn: &inspect/1)
      assert policy.strategy == :summary
    end

    test "raises for negative window_size" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        ContextPolicy.new!(strategy: :sliding_window, window_size: -1)
      end
    end

    test "raises for negative head" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        ContextPolicy.new!(strategy: :head_tail, head: -1, tail: 5)
      end
    end

    test "raises for zero tail" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        ContextPolicy.new!(strategy: :head_tail, head: 2, tail: 0)
      end
    end

    test "raises for invalid strategy" do
      assert_raise ArgumentError, ~r/invalid strategy/, fn ->
        ContextPolicy.new!(strategy: :bogus)
      end
    end

    test "raises for :summary without summarize_fn" do
      assert_raise ArgumentError, ~r/summarize_fn/, fn ->
        ContextPolicy.new!(strategy: :summary)
      end
    end

    test "raises for :summary with non-function summarize_fn" do
      assert_raise ArgumentError, ~r/1-arity function/, fn ->
        ContextPolicy.new!(strategy: :summary, summarize_fn: "not a fn")
      end
    end
  end

  describe "apply/2 with :none" do
    test "returns messages unchanged" do
      messages = make_messages([{:user, "hello"}, {:assistant, "hi"}])
      policy = ContextPolicy.new!(strategy: :none)
      assert ContextPolicy.apply(policy, messages) == messages
    end
  end

  describe "apply/2 with :sliding_window" do
    test "keeps last window_size non-system messages" do
      messages =
        make_messages([
          {:system, "sys"},
          {:user, "msg1"},
          {:assistant, "msg2"},
          {:user, "msg3"},
          {:assistant, "msg4"},
          {:user, "msg5"}
        ])

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)
      result = ContextPolicy.apply(policy, messages)

      # System preserved, plus last 2 non-system, plus latest user ensured
      roles = Enum.map(result, & &1.role)
      assert :system in roles
      # Latest user message must be present
      assert List.last(Enum.filter(result, &(&1.role == :user))).content == "msg5"
    end

    test "preserves all when within window" do
      messages = make_messages([{:user, "a"}, {:assistant, "b"}])
      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 10)
      result = ContextPolicy.apply(policy, messages)
      assert length(result) == 2
    end

    test "preserves system messages" do
      messages =
        make_messages([
          {:system, "instructions"},
          {:user, "m1"},
          {:assistant, "m2"},
          {:user, "m3"},
          {:assistant, "m4"},
          {:user, "m5"},
          {:assistant, "m6"}
        ])

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)
      result = ContextPolicy.apply(policy, messages)

      assert Enum.any?(result, &(&1.role == :system && &1.content == "instructions"))
    end

    test "empty message list" do
      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 5)
      assert ContextPolicy.apply(policy, []) == []
    end

    test "keeps tool-call + tool-result pairs intact" do
      tc = fake_tool_call()

      messages =
        make_messages([
          {:user, "do something"},
          {:assistant_tc, nil, [tc]},
          {:tool, "result"},
          {:user, "thanks"}
        ])

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)
      result = ContextPolicy.apply(policy, messages)

      # The tool pair should be kept intact — if assistant with tool_calls is present,
      # the tool result should follow it
      assistant_tc = Enum.find(result, &(&1.role == :assistant && &1.tool_calls != []))
      tool_result = Enum.find(result, &(&1.role == :tool))

      if assistant_tc do
        assert tool_result != nil, "tool result should accompany tool call"
        ai = Enum.find_index(result, &(&1 == assistant_tc))
        ti = Enum.find_index(result, &(&1 == tool_result))
        assert ti == ai + 1, "tool result should immediately follow tool call"
      end
    end
  end

  describe "apply/2 with :head_tail" do
    test "keeps head and tail messages" do
      messages =
        make_messages([
          {:user, "first"},
          {:assistant, "second"},
          {:user, "third"},
          {:assistant, "fourth"},
          {:user, "fifth"},
          {:assistant, "sixth"}
        ])

      policy = ContextPolicy.new!(strategy: :head_tail, head: 1, tail: 2)
      result = ContextPolicy.apply(policy, messages)

      # Should have first message + last 2 messages
      contents = Enum.map(result, & &1.content)
      assert "first" in contents
      assert "sixth" in contents
    end

    test "preserves all when fewer than head + tail" do
      messages = make_messages([{:user, "a"}, {:assistant, "b"}])
      policy = ContextPolicy.new!(strategy: :head_tail, head: 2, tail: 3)
      assert length(ContextPolicy.apply(policy, messages)) == 2
    end

    test "preserves system messages" do
      messages =
        make_messages([
          {:system, "sys"},
          {:user, "a"},
          {:assistant, "b"},
          {:user, "c"},
          {:assistant, "d"},
          {:user, "e"}
        ])

      policy = ContextPolicy.new!(strategy: :head_tail, head: 1, tail: 1)
      result = ContextPolicy.apply(policy, messages)
      assert Enum.any?(result, &(&1.role == :system))
    end
  end

  describe "apply/2 with :summary" do
    test "summarizes discarded messages" do
      messages =
        make_messages([
          {:user, "m1"},
          {:assistant, "m2"},
          {:user, "m3"},
          {:assistant, "m4"},
          {:user, "m5"}
        ])

      summarize = fn discarded ->
        "Summary of #{length(discarded)} messages"
      end

      policy =
        ContextPolicy.new!(
          strategy: :summary,
          window_size: 2,
          summarize_fn: summarize
        )

      result = ContextPolicy.apply(policy, messages)

      summary = Enum.find(result, fn m -> m.metadata[:synthetic] == true end)
      assert summary != nil
      assert summary.content =~ "Summary of"
    end

    test "no compaction when within window" do
      messages = make_messages([{:user, "a"}, {:assistant, "b"}])

      policy =
        ContextPolicy.new!(
          strategy: :summary,
          window_size: 10,
          summarize_fn: fn _ -> "sum" end
        )

      result = ContextPolicy.apply(policy, messages)
      assert length(result) == 2
    end
  end

  describe "invariant: latest user message" do
    test "latest user message always preserved with sliding_window" do
      messages =
        make_messages([
          {:user, "old"},
          {:assistant, "reply"},
          {:user, "latest_question"}
        ])

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 1)
      result = ContextPolicy.apply(policy, messages)

      user_msgs = Enum.filter(result, &(&1.role == :user))
      assert Enum.any?(user_msgs, &(&1.content == "latest_question"))
    end
  end

  describe "invariant: interleaved system message ordering" do
    test "system messages preserve original position with sliding_window" do
      messages =
        make_messages([
          {:system, "sys1"},
          {:user, "u1"},
          {:assistant, "a1"},
          {:system, "sys2"},
          {:user, "u2"},
          {:assistant, "a2"},
          {:user, "u3"},
          {:assistant, "a3"}
        ])

      # window_size: 2 keeps last 2 non-system entries (u3, a3)
      # sys1 and sys2 should remain at their original positions relative to kept messages
      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)
      result = ContextPolicy.apply(policy, messages)

      contents = Enum.map(result, & &1.content)

      # Both system messages preserved
      assert "sys1" in contents
      assert "sys2" in contents

      # sys1 must appear before sys2
      sys1_idx = Enum.find_index(contents, &(&1 == "sys1"))
      sys2_idx = Enum.find_index(contents, &(&1 == "sys2"))
      assert sys1_idx < sys2_idx

      # sys2 must appear before the non-system messages it originally preceded
      u3_idx = Enum.find_index(contents, &(&1 == "u3"))
      assert sys2_idx < u3_idx

      # No discarded non-system messages leak through
      refute "u1" in contents
      refute "a1" in contents
    end

    test "system messages preserve original position with head_tail" do
      messages =
        make_messages([
          {:user, "u1"},
          {:system, "mid_sys"},
          {:assistant, "a1"},
          {:user, "u2"},
          {:assistant, "a2"},
          {:user, "u3"},
          {:assistant, "a3"}
        ])

      # head: 1, tail: 1 keeps first non-system (u1) and last non-system (a3)
      policy = ContextPolicy.new!(strategy: :head_tail, head: 1, tail: 1)
      result = ContextPolicy.apply(policy, messages)

      contents = Enum.map(result, & &1.content)

      # System message preserved
      assert "mid_sys" in contents

      # u1 (head), a3 (tail) kept; mid_sys between them in original order
      u1_idx = Enum.find_index(contents, &(&1 == "u1"))
      sys_idx = Enum.find_index(contents, &(&1 == "mid_sys"))
      a3_idx = Enum.find_index(contents, &(&1 == "a3"))

      assert u1_idx < sys_idx, "u1 should come before mid_sys"
      assert sys_idx < a3_idx, "mid_sys should come before a3"
    end

    test "multiple interleaved system messages maintain relative order" do
      messages =
        make_messages([
          {:system, "sys_a"},
          {:user, "u1"},
          {:system, "sys_b"},
          {:assistant, "a1"},
          {:user, "u2"},
          {:system, "sys_c"},
          {:assistant, "a2"},
          {:user, "u3"}
        ])

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2)
      result = ContextPolicy.apply(policy, messages)

      contents = Enum.map(result, & &1.content)

      # All three system messages preserved in order
      sys_indices =
        contents
        |> Enum.with_index()
        |> Enum.filter(fn {c, _i} -> c in ["sys_a", "sys_b", "sys_c"] end)
        |> Enum.map(fn {c, _i} -> c end)

      assert sys_indices == ["sys_a", "sys_b", "sys_c"]
    end
  end

  describe "keep_system option" do
    test "system messages not preserved when keep_system is false" do
      messages =
        make_messages([
          {:system, "instructions"},
          {:user, "a"},
          {:assistant, "b"},
          {:user, "c"},
          {:assistant, "d"},
          {:user, "e"}
        ])

      policy = ContextPolicy.new!(strategy: :sliding_window, window_size: 2, keep_system: false)
      result = ContextPolicy.apply(policy, messages)

      # System messages should be in the compaction pool, not preserved
      # The exact behavior depends on whether system ends up in the window
      refute Enum.any?(result, &(&1.role == :system && &1.content == "instructions"))
    end
  end
end
