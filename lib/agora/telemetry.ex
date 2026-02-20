defmodule Agora.Telemetry do
  @moduledoc """
  Telemetry helpers and canonical event documentation for the Agora framework.

  This module provides thin wrappers around `:telemetry` functions and serves
  as the single reference for all telemetry events emitted by Agora (28 events
  across 11 event prefixes).

  ## Event Reference

  ### Agent Events

  Agent events are emitted by `Agora.Agent` using manual `:telemetry.execute/3` calls.
  This is intentional — they predate the `span/3` helper and use `system_time` in start
  measurements rather than `monotonic_time`. Changing this would break existing handler
  assertions for no behavioral gain.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :agent, :run, :start]` | `%{system_time}` | `%{provider, model, agent_name, max_iterations}` |
  | `[:agora, :agent, :run, :stop]` | `%{duration, iterations}` | `%{provider, model, agent_name, max_iterations}` + optional `:error` |
  | `[:agora, :agent, :run, :exception]` | `%{duration}` | `%{provider, model, agent_name, max_iterations, kind, reason, stacktrace}` |
  | `[:agora, :agent, :loop_iteration, :start]` | `%{system_time}` | `%{provider, model, agent_name, max_iterations, iteration}` |
  | `[:agora, :agent, :loop_iteration, :stop]` | `%{duration}` | `%{provider, model, agent_name, max_iterations, iteration}` + optional `:has_tool_calls`, `:error` |

  ### Provider Events

  Emitted by `Agora.Provider.chat/3` using `span/3`. Only fires when provider
  resolution succeeds — config errors from `resolve/1` do not emit events.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :provider, :call, :start]` | `%{monotonic_time, system_time}` | `%{provider, model, message_count}` |
  | `[:agora, :provider, :call, :stop]` | `%{duration, monotonic_time}` | `%{provider, model, message_count}` + optional `:error` |
  | `[:agora, :provider, :call, :exception]` | `%{duration, monotonic_time}` | `%{provider, model, message_count, kind, reason, stacktrace}` |

  ### Tool Events

  Emitted by `Agora.ToolBroker`. Outer-level `start`/`stop` in `execute/4` pair
  around each tool call. Under normal operation (valid supervisor), every `:start`
  has a matching `:stop`. If `Task.Supervisor.async_nolink/2` itself raises (e.g.,
  supervisor not running), a `:start` may lack a `:stop`. Inner-level `:exception`
  in `execute_single/4` fires additionally when tools crash inside the task.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :tool, :call, :start]` | `%{system_time}` | `%{tool_name, tool_call_id}` |
  | `[:agora, :tool, :call, :stop]` | `%{duration}` | `%{tool_name, tool_call_id, status}` where status is `:ok \\| :error \\| :timeout \\| :exit` |
  | `[:agora, :tool, :call, :exception]` | `%{duration: 0}` | `%{tool_name, tool_call_id, kind, reason}` |

  ### Middleware Events

  Emitted by `Agora.Middleware.Chain.run/2` using `span/3`. Empty middleware
  lists skip telemetry entirely (fast path).

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :middleware, :call, :start]` | `%{monotonic_time, system_time}` | `%{hook, middleware_count}` |
  | `[:agora, :middleware, :call, :stop]` | `%{duration, monotonic_time}` | `%{hook, middleware_count}` + optional `:halt_reason` |

  ### Orchestrator Events

  Orchestrator events are emitted by `Agora.Orchestrator.Runner` using manual
  `:telemetry.execute/3` calls (same pattern as Agent events).

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :orchestrator, :run, :start]` | `%{system_time}` | `%{orchestrator, name}` |
  | `[:agora, :orchestrator, :run, :stop]` | `%{duration, steps}` | `%{orchestrator, name, steps}` + optional `:error` |
  | `[:agora, :orchestrator, :step, :start]` | `%{system_time}` | `%{orchestrator, agent, step}` |
  | `[:agora, :orchestrator, :step, :stop]` | `%{duration}` | `%{orchestrator, agent, step}` |

  ### Workflow Events

  Emitted by `Agora.Workflow.Executor` using `span/3`.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :workflow, :run, :start]` | `%{monotonic_time, system_time}` | `%{workflow_id, step_count}` |
  | `[:agora, :workflow, :run, :stop]` | `%{duration, monotonic_time}` | `%{workflow_id, step_count}` + optional `:error` |
  | `[:agora, :workflow, :run, :exception]` | `%{duration, monotonic_time}` | `%{workflow_id, step_count, kind, reason, stacktrace}` |
  | `[:agora, :workflow, :step, :start]` | `%{monotonic_time, system_time}` | `%{step_id, step_name}` |
  | `[:agora, :workflow, :step, :stop]` | `%{duration, monotonic_time}` | `%{step_id, step_name}` + optional `:error` |
  | `[:agora, :workflow, :step, :exception]` | `%{duration, monotonic_time}` | `%{step_id, step_name, kind, reason, stacktrace}` |

  ### Provider Streaming Events

  Emitted by `Agora.Provider.stream_chat/3`. The `:start` event fires before
  the streaming task is spawned. The `:stop` event fires when the streaming
  task completes (either successfully or with error).

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :provider, :stream, :start]` | `%{system_time}` | `%{provider, model, message_count}` |
  | `[:agora, :provider, :stream, :stop]` | `%{duration}` | `%{provider, model, message_count}` + optional `:error` |

  ### Agent Streaming Events

  Emitted by `Agora.Agent` for `stream_run/2` operations. Uses manual
  `:telemetry.execute/3` calls (same pattern as `run/2` events).

  Note: `[:agora, :agent, :loop_iteration, ...]` events are NOT emitted during
  streaming — the streaming loop structure differs from the synchronous
  `reasoning_loop`.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:agora, :agent, :stream_run, :start]` | `%{system_time}` | `%{provider, model, agent_name, max_iterations}` |
  | `[:agora, :agent, :stream_run, :stop]` | `%{duration, iterations}` | `%{provider, model, agent_name, max_iterations}` + optional `:error` |
  | `[:agora, :agent, :stream_run, :memory_error]` | `%{system_time}` | `%{error}` |

  The `:memory_error` event fires when memory save or reload fails after a streaming
  run completes. The stream has already been closed (`:done` sent to caller), so this
  error cannot be communicated via the stream. The agent transitions to `:idle` regardless.
  """

  @doc """
  Executes a telemetry span with the given event prefix and metadata.

  Wraps `:telemetry.span/3`. The `span_fn` must return `{result, stop_metadata}`.
  Emits `prefix ++ [:start]` before the function, and `prefix ++ [:stop]` or
  `prefix ++ [:exception]` after.

  ## Examples

      Agora.Telemetry.span([:agora, :provider, :call], %{provider: :echo}, fn ->
        result = do_work()
        {result, %{provider: :echo}}
      end)

  """
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(event_prefix, metadata, span_fn) do
    :telemetry.span(event_prefix, metadata, span_fn)
  end

  @doc """
  Emits a single telemetry event with the given measurements and metadata.

  Delegates to `:telemetry.execute/3`.

  ## Examples

      Agora.Telemetry.emit([:agora, :tool, :call, :start], %{system_time: System.system_time()}, %{tool_name: "calc"})

  """
  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
