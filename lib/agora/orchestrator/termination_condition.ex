defmodule Agora.Orchestrator.TerminationCondition do
  @moduledoc """
  Composable termination conditions for orchestration runs.

  Conditions are 1-arity functions that receive the orchestration context
  and return `:continue` or `{:done, Message.t()}`. They are checked by
  the Runner before each orchestration step.

  ## Example

      alias Agora.Orchestrator.TerminationCondition

      # Stop after 5 turns or when "DONE" appears in response
      condition = TerminationCondition.any_of([
        TerminationCondition.max_turns(5),
        TerminationCondition.keyword_match(["DONE"])
      ])

  """

  alias Agora.Message

  @type condition :: (context :: map() -> :continue | {:done, Message.t()})

  @doc """
  Returns a condition that triggers after `n` turns have been recorded in history.
  """
  @spec max_turns(pos_integer()) :: condition()
  def max_turns(n) when is_integer(n) and n > 0 do
    fn context ->
      if length(context.history) >= n do
        last_content = last_response_content(context)
        {:done, Message.assistant(last_content || "Reached maximum turns (#{n})")}
      else
        :continue
      end
    end
  end

  @doc """
  Returns a condition that triggers when any keyword is found in the last response.

  Matching is case-insensitive substring search. Handles nil content and
  empty history safely (returns `:continue`).
  """
  @spec keyword_match([String.t()]) :: condition()
  def keyword_match(keywords) when is_list(keywords) do
    fn context ->
      case last_response_content(context) do
        nil ->
          :continue

        content ->
          downcased = String.downcase(content)

          if Enum.any?(keywords, &String.contains?(downcased, String.downcase(&1))) do
            {:done, Message.assistant(content)}
          else
            :continue
          end
      end
    end
  end

  @doc """
  Wraps an arbitrary function as a termination condition (passthrough).
  """
  @spec custom(condition()) :: condition()
  def custom(fun) when is_function(fun, 1), do: fun

  @doc """
  Composes conditions with OR semantics — first match wins.

  Returns `:continue` only if all conditions return `:continue`.
  """
  @spec any_of([condition()]) :: condition()
  def any_of(conditions) when is_list(conditions) do
    fn context ->
      Enum.find_value(conditions, :continue, fn condition ->
        case condition.(context) do
          :continue -> nil
          {:done, _msg} = done -> done
        end
      end)
    end
  end

  @doc """
  Composes conditions with AND semantics — all must agree.

  Returns `{:done, msg}` only if all conditions return `{:done, _}`.
  Uses the last condition's message.
  """
  @spec all_of([condition()]) :: condition()
  def all_of([]) do
    fn _context -> :continue end
  end

  def all_of(conditions) when is_list(conditions) do
    fn context ->
      results = Enum.map(conditions, & &1.(context))

      if Enum.all?(results, fn result -> match?({:done, _}, result) end) do
        List.last(results)
      else
        :continue
      end
    end
  end

  defp last_response_content(%{history: []}), do: nil

  defp last_response_content(%{history: history}) do
    case List.last(history) do
      %{output: {:ok, %Message{content: content}}} -> content
      _ -> nil
    end
  end
end
