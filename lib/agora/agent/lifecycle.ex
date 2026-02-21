defmodule Agora.Agent.Lifecycle do
  @moduledoc """
  Defines state machine lifecycle for agents with discrete states.

  A lifecycle configuration specifies:
  - Named states with optional config overlays (instructions, tools, middleware, etc.)
  - Transitions between states triggered by tool calls, message matches, or timeouts
  - Enter/exit callbacks per state

  ## Example

      Lifecycle.new!(
        initial_state: :collecting_info,
        states: %{
          collecting_info: %StateConfig{
            instructions: "Ask the user for their name and email."
          },
          processing: %StateConfig{
            instructions: "Process the collected information.",
            tools: [MyApp.ProcessingTool]
          }
        },
        transitions: [
          %{from: :collecting_info, to: :processing,
            trigger: {:tool_call, "submit_info"}}
        ]
      )

  ## Transition Triggers

  - `{:tool_call, name}` — fires when the named tool was called during the run
  - `{:tool_result, name, predicate}` — fires when the named tool's result satisfies the predicate
  - `{:message_match, predicate}` — fires when the final response satisfies the predicate
  - `{:state_timeout, milliseconds}` — fires after the timeout elapses (max one per source state)

  ## Transition Evaluation

  Transitions are an ordered list evaluated first-match after each `run/2` call.
  Guard functions receive a context map and can filter transitions further.
  """

  alias Agora.Agent.Loop.RunResult

  defmodule StateConfig do
    @moduledoc """
    Per-state configuration overlay. `nil` fields inherit from base `AgentConfig`.
    """
    @type t :: %__MODULE__{
            instructions: String.t() | nil,
            tools: list() | nil,
            middleware: list() | nil,
            max_iterations: pos_integer() | nil,
            provider_opts: keyword() | nil
          }

    defstruct [:instructions, :tools, :middleware, :max_iterations, :provider_opts]
  end

  @type transition_trigger ::
          {:tool_call, tool_name :: String.t()}
          | {:tool_result, tool_name :: String.t(), (Agora.ToolResult.t() -> boolean())}
          | {:message_match, (Agora.Message.t() -> boolean())}
          | {:state_timeout, pos_integer()}

  @type transition_context :: %{
          facts: RunResult.facts(),
          outcome: {:done, Agora.Message.t()} | {:error, Agora.Error.t()},
          from: atom(),
          to: atom()
        }

  @type transition :: %{
          from: atom(),
          to: atom(),
          trigger: transition_trigger(),
          guard: (transition_context() -> boolean()) | nil
        }

  @type lifecycle_callback :: (from_state :: atom(), to_state :: atom() -> :ok)

  @type t :: %__MODULE__{
          initial_state: atom(),
          states: %{atom() => StateConfig.t()},
          transitions: [transition()],
          on_enter: %{atom() => lifecycle_callback()},
          on_exit: %{atom() => lifecycle_callback()}
        }

  defstruct [:initial_state, states: %{}, transitions: [], on_enter: %{}, on_exit: %{}]

  @doc """
  Validates a lifecycle configuration, returning `{:ok, lifecycle}` or `{:error, reason}`.

  Used by `StateMachine.init/1` to catch invalid structs that bypass `new!/1`.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = lc) do
    validate!(lc)
    {:ok, lc}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  @doc """
  Creates a validated lifecycle configuration, raising on invalid input.

  ## Validations

  - `initial_state` must exist in `states`
  - At least one state must be defined
  - All transition `from` and `to` must reference defined states
  - At most one `{:state_timeout, _}` trigger per source state
  - All `on_enter`/`on_exit` keys must reference defined states
  - Guard functions must be 1-arity
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    lifecycle = struct!(__MODULE__, opts)
    validate!(lifecycle)
    lifecycle
  end

  defp validate!(%__MODULE__{} = lc) do
    validate_states!(lc)
    validate_initial_state!(lc)
    validate_transitions!(lc)
    validate_callbacks!(lc)
    :ok
  end

  defp validate_states!(%{states: states}) when map_size(states) == 0 do
    raise ArgumentError, "lifecycle must define at least one state"
  end

  defp validate_states!(_), do: :ok

  defp validate_initial_state!(%{initial_state: nil}) do
    raise ArgumentError, "lifecycle :initial_state is required"
  end

  defp validate_initial_state!(%{initial_state: state, states: states}) do
    unless Map.has_key?(states, state) do
      raise ArgumentError,
            "initial_state #{inspect(state)} not found in states: #{inspect(Map.keys(states))}"
    end
  end

  defp validate_transitions!(%{transitions: transitions, states: states}) do
    state_names = Map.keys(states)
    timeout_counts = %{}

    Enum.reduce(transitions, timeout_counts, fn transition, counts ->
      validate_transition_states!(transition, state_names)
      validate_transition_trigger!(transition)
      validate_transition_guard!(transition)
      track_timeout(transition, counts)
    end)

    :ok
  end

  defp validate_transition_states!(%{from: from, to: to}, state_names) do
    unless from in state_names do
      raise ArgumentError,
            "transition :from #{inspect(from)} not found in states: #{inspect(state_names)}"
    end

    unless to in state_names do
      raise ArgumentError,
            "transition :to #{inspect(to)} not found in states: #{inspect(state_names)}"
    end
  end

  defp validate_transition_trigger!(%{trigger: {:tool_call, name}}) when is_binary(name), do: :ok

  defp validate_transition_trigger!(%{trigger: {:tool_result, name, pred}})
       when is_binary(name) and is_function(pred, 1), do: :ok

  defp validate_transition_trigger!(%{trigger: {:message_match, pred}}) when is_function(pred, 1),
    do: :ok

  defp validate_transition_trigger!(%{trigger: {:state_timeout, ms}})
       when is_integer(ms) and ms > 0, do: :ok

  defp validate_transition_trigger!(%{trigger: trigger}) do
    raise ArgumentError, "invalid transition trigger: #{inspect(trigger)}"
  end

  defp validate_transition_guard!(%{guard: nil}), do: :ok
  defp validate_transition_guard!(%{guard: fun}) when is_function(fun, 1), do: :ok

  defp validate_transition_guard!(%{guard: guard}) do
    raise ArgumentError,
          "transition :guard must be nil or a 1-arity function, got: #{inspect(guard)}"
  end

  defp track_timeout(%{trigger: {:state_timeout, _}, from: from}, counts) do
    new_count = Map.get(counts, from, 0) + 1

    if new_count > 1 do
      raise ArgumentError,
            "state #{inspect(from)} has more than one :state_timeout transition (gen_statem supports one at a time)"
    end

    Map.put(counts, from, new_count)
  end

  defp track_timeout(_, counts), do: counts

  defp validate_callbacks!(%{on_enter: on_enter, on_exit: on_exit, states: states}) do
    state_names = Map.keys(states)

    for {state, fun} <- on_enter do
      unless state in state_names do
        raise ArgumentError,
              "on_enter callback for #{inspect(state)} not found in states: #{inspect(state_names)}"
      end

      unless is_function(fun, 2) do
        raise ArgumentError,
              "on_enter callback for #{inspect(state)} must be a 2-arity function, got: #{inspect(fun)}"
      end
    end

    for {state, fun} <- on_exit do
      unless state in state_names do
        raise ArgumentError,
              "on_exit callback for #{inspect(state)} not found in states: #{inspect(state_names)}"
      end

      unless is_function(fun, 2) do
        raise ArgumentError,
              "on_exit callback for #{inspect(state)} must be a 2-arity function, got: #{inspect(fun)}"
      end
    end
  end
end
