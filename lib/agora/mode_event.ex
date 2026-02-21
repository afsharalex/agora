defmodule Agora.ModeEvent do
  @moduledoc """
  Represents a single event in a mode-level execution stream.

  Mode events are orchestration-level events emitted by the Runner and Executor
  during `run_mode_stream/3` execution. They provide visibility into intermediate
  progress: which agent was selected, when steps start/complete, handoffs, replans, etc.

  ## Event Types

  | Type | Data | Description |
  |---|---|---|
  | `:mode_started` | `%{input_type: atom(), input_size: non_neg_integer()}` | Execution began |
  | `:agent_selected` | `%{agent: atom(), turn: integer()}` | Orchestrator selected an agent |
  | `:step_started` | `%{agent: atom(), turn: integer()}` or `%{step_id: atom()}` | Step execution began |
  | `:step_completed` | `%{agent: atom(), turn: integer(), result: atom()}` or `%{step_id: atom(), result: ...}` | Step execution completed |
  | `:handoff` | `%{from: atom(), to: atom(), message: String.t()}` | Handoff between agents |
  | `:replan` | `%{replan_count: integer(), reason: String.t()}` | Plan orchestrator replanning |
  | `:mode_completed` | `%{turns: integer()}` | Execution completed successfully |
  | `:mode_failed` | `%{error: Error.t(), turns: integer()}` | Execution failed |
  | `:mode_cancelled` | `%{boundary: atom(), turn: integer()}` | Execution cancelled |
  | `:context_compacted` | `%{strategy: atom(), before: integer(), after: integer()}` | Messages compacted |
  | `:done` | `%{}` | Terminal signal for stream (normal completion) |
  | `:error` | `%Error{}` | Terminal signal for stream (crash/timeout) |

  ## Relationship to StreamEvent

  `StreamEvent` is LLM-level (text deltas, tool calls). `ModeEvent` is
  orchestration-level (agent selection, step completion, handoffs). They use
  separate structs to keep concerns clean.
  """

  alias Agora.Error

  @type event_type ::
          :mode_started
          | :agent_selected
          | :step_started
          | :step_completed
          | :handoff
          | :replan
          | :mode_completed
          | :mode_failed
          | :mode_cancelled
          | :context_compacted
          | :done
          | :error

  @type t :: %__MODULE__{
          type: event_type(),
          mode: atom() | nil,
          data: term(),
          timestamp: integer(),
          metadata: map()
        }

  @derive Jason.Encoder
  defstruct [:type, :mode, :data, :timestamp, metadata: %{}]

  @doc "Creates a mode_started event with redacted input metadata."
  @spec mode_started(atom(), atom(), non_neg_integer(), map()) :: t()
  def mode_started(mode, input_type, input_size, metadata \\ %{}) do
    %__MODULE__{
      type: :mode_started,
      mode: mode,
      data: %{input_type: input_type, input_size: input_size},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates an agent_selected event."
  @spec agent_selected(atom(), atom(), non_neg_integer(), map()) :: t()
  def agent_selected(mode, agent, turn, metadata \\ %{}) do
    %__MODULE__{
      type: :agent_selected,
      mode: mode,
      data: %{agent: agent, turn: turn},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a step_started event for orchestrator modes."
  @spec step_started(atom(), atom(), non_neg_integer(), map()) :: t()
  def step_started(mode, agent, turn, metadata \\ %{}) do
    %__MODULE__{
      type: :step_started,
      mode: mode,
      data: %{agent: agent, turn: turn},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a step_started event for workflow modes."
  @spec workflow_step_started(atom(), atom(), map()) :: t()
  def workflow_step_started(mode, step_id, metadata \\ %{}) do
    %__MODULE__{
      type: :step_started,
      mode: mode,
      data: %{step_id: step_id},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a step_completed event for orchestrator modes."
  @spec step_completed(atom(), atom(), non_neg_integer(), :ok | :error, map()) :: t()
  def step_completed(mode, agent, turn, result, metadata \\ %{}) do
    %__MODULE__{
      type: :step_completed,
      mode: mode,
      data: %{agent: agent, turn: turn, result: result},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a step_completed event for workflow modes."
  @spec workflow_step_completed(atom(), atom(), :ok | :error | :skipped, map()) :: t()
  def workflow_step_completed(mode, step_id, result, metadata \\ %{}) do
    %__MODULE__{
      type: :step_completed,
      mode: mode,
      data: %{step_id: step_id, result: result},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a handoff event."
  @spec handoff(atom(), atom(), atom(), String.t(), map()) :: t()
  def handoff(mode, from, to, message, metadata \\ %{}) do
    %__MODULE__{
      type: :handoff,
      mode: mode,
      data: %{from: from, to: to, message: message},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a replan event."
  @spec replan(atom(), non_neg_integer(), String.t(), map()) :: t()
  def replan(mode, replan_count, reason, metadata \\ %{}) do
    %__MODULE__{
      type: :replan,
      mode: mode,
      data: %{replan_count: replan_count, reason: reason},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a mode_completed event."
  @spec mode_completed(atom(), non_neg_integer(), map()) :: t()
  def mode_completed(mode, turns, metadata \\ %{}) do
    %__MODULE__{
      type: :mode_completed,
      mode: mode,
      data: %{turns: turns},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a mode_failed event."
  @spec mode_failed(atom(), Error.t(), non_neg_integer(), map()) :: t()
  def mode_failed(mode, %Error{} = error, turns, metadata \\ %{}) do
    %__MODULE__{
      type: :mode_failed,
      mode: mode,
      data: %{error: error, turns: turns},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a mode_cancelled event."
  @spec mode_cancelled(atom(), atom(), non_neg_integer(), map()) :: t()
  def mode_cancelled(mode, boundary, turn, metadata \\ %{}) do
    %__MODULE__{
      type: :mode_cancelled,
      mode: mode,
      data: %{boundary: boundary, turn: turn},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a context_compacted event."
  @spec context_compacted(atom(), atom(), non_neg_integer(), non_neg_integer(), map()) :: t()
  def context_compacted(mode, strategy, before_count, after_count, metadata \\ %{}) do
    %__MODULE__{
      type: :context_compacted,
      mode: mode,
      data: %{strategy: strategy, before: before_count, after: after_count},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates a done event signaling stream completion."
  @spec done(map()) :: t()
  def done(metadata \\ %{}) do
    %__MODULE__{
      type: :done,
      data: %{},
      timestamp: System.system_time(),
      metadata: metadata
    }
  end

  @doc "Creates an error event for stream crash/timeout."
  @spec error(Error.t(), map()) :: t()
  def error(%Error{} = err, metadata \\ %{}) do
    %__MODULE__{
      type: :error,
      data: err,
      timestamp: System.system_time(),
      metadata: metadata
    }
  end
end
