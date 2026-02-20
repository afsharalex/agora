defmodule Agora.Orchestrator.TerminationConditionTest do
  use ExUnit.Case, async: true

  alias Agora.Message
  alias Agora.Orchestrator.TerminationCondition

  defp context_with_history(turns) do
    %{
      original_input: Message.user("test"),
      history: turns
    }
  end

  defp turn(agent, content) do
    %{
      agent: agent,
      input: Message.user("input"),
      output: {:ok, Message.assistant(content)}
    }
  end

  defp error_turn(agent) do
    %{
      agent: agent,
      input: Message.user("input"),
      output: {:error, Agora.Error.new(:provider_error, "fail")}
    }
  end

  describe "max_turns/1" do
    test "continues when under limit" do
      condition = TerminationCondition.max_turns(3)
      context = context_with_history([turn(:a, "one"), turn(:b, "two")])

      assert condition.(context) == :continue
    end

    test "done when at limit" do
      condition = TerminationCondition.max_turns(2)
      context = context_with_history([turn(:a, "one"), turn(:b, "two")])

      assert {:done, %Message{role: :assistant}} = condition.(context)
    end

    test "done when over limit" do
      condition = TerminationCondition.max_turns(1)
      context = context_with_history([turn(:a, "one"), turn(:b, "two")])

      assert {:done, %Message{}} = condition.(context)
    end

    test "uses last response content in done message" do
      condition = TerminationCondition.max_turns(2)
      context = context_with_history([turn(:a, "one"), turn(:b, "final answer")])

      assert {:done, %Message{content: "final answer"}} = condition.(context)
    end

    test "handles empty history" do
      condition = TerminationCondition.max_turns(1)
      context = context_with_history([])

      assert condition.(context) == :continue
    end
  end

  describe "keyword_match/1" do
    test "continues when keyword absent" do
      condition = TerminationCondition.keyword_match(["DONE"])
      context = context_with_history([turn(:a, "still working")])

      assert condition.(context) == :continue
    end

    test "done when keyword found" do
      condition = TerminationCondition.keyword_match(["DONE"])
      context = context_with_history([turn(:a, "I am DONE now")])

      assert {:done, %Message{content: "I am DONE now"}} = condition.(context)
    end

    test "case insensitive matching" do
      condition = TerminationCondition.keyword_match(["done"])
      context = context_with_history([turn(:a, "I am DONE")])

      assert {:done, _} = condition.(context)
    end

    test "matches any keyword in list" do
      condition = TerminationCondition.keyword_match(["STOP", "DONE", "QUIT"])
      context = context_with_history([turn(:a, "I will QUIT")])

      assert {:done, _} = condition.(context)
    end

    test "handles empty history" do
      condition = TerminationCondition.keyword_match(["DONE"])
      context = context_with_history([])

      assert condition.(context) == :continue
    end

    test "handles nil content in last response" do
      nil_turn = %{
        agent: :a,
        input: Message.user("input"),
        output: {:ok, Message.assistant(nil, [])}
      }

      condition = TerminationCondition.keyword_match(["DONE"])
      context = context_with_history([nil_turn])

      assert condition.(context) == :continue
    end

    test "handles error output in last turn" do
      condition = TerminationCondition.keyword_match(["DONE"])
      context = context_with_history([error_turn(:a)])

      assert condition.(context) == :continue
    end
  end

  describe "custom/1" do
    test "delegates to function" do
      condition = TerminationCondition.custom(fn _ctx -> :continue end)
      context = context_with_history([])

      assert condition.(context) == :continue
    end

    test "passes through done result" do
      msg = Message.assistant("custom done")

      condition =
        TerminationCondition.custom(fn _ctx -> {:done, msg} end)

      context = context_with_history([])

      assert {:done, ^msg} = condition.(context)
    end
  end

  describe "any_of/1" do
    test "first match wins" do
      c1 = TerminationCondition.keyword_match(["DONE"])
      c2 = TerminationCondition.max_turns(1)
      condition = TerminationCondition.any_of([c1, c2])

      context = context_with_history([turn(:a, "DONE")])

      assert {:done, %Message{content: "DONE"}} = condition.(context)
    end

    test "continues when none match" do
      c1 = TerminationCondition.keyword_match(["DONE"])
      c2 = TerminationCondition.max_turns(10)
      condition = TerminationCondition.any_of([c1, c2])

      context = context_with_history([turn(:a, "still going")])

      assert condition.(context) == :continue
    end

    test "returns done if any single condition matches" do
      c1 = TerminationCondition.max_turns(1)
      c2 = TerminationCondition.keyword_match(["NOPE"])
      condition = TerminationCondition.any_of([c1, c2])

      context = context_with_history([turn(:a, "hello")])

      assert {:done, _} = condition.(context)
    end
  end

  describe "all_of/1" do
    test "all must agree — returns done when all match" do
      c1 = TerminationCondition.max_turns(1)
      c2 = TerminationCondition.keyword_match(["DONE"])
      condition = TerminationCondition.all_of([c1, c2])

      context = context_with_history([turn(:a, "DONE")])

      assert {:done, _} = condition.(context)
    end

    test "continues when any disagrees" do
      c1 = TerminationCondition.max_turns(1)
      c2 = TerminationCondition.keyword_match(["FINISHED"])
      condition = TerminationCondition.all_of([c1, c2])

      # max_turns(1) triggers (1 turn >= 1), but keyword "FINISHED" is not in content
      context = context_with_history([turn(:a, "still working")])

      assert condition.(context) == :continue
    end

    test "uses last condition's message" do
      c1 = TerminationCondition.max_turns(1)
      c2 = TerminationCondition.keyword_match(["DONE"])
      condition = TerminationCondition.all_of([c1, c2])

      context = context_with_history([turn(:a, "DONE")])

      # keyword_match is last, so its message is used
      assert {:done, %Message{content: "DONE"}} = condition.(context)
    end

    test "empty list returns :continue" do
      condition = TerminationCondition.all_of([])
      context = context_with_history([turn(:a, "anything")])

      assert condition.(context) == :continue
    end
  end
end
