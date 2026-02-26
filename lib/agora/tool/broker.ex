defmodule Agora.ToolBroker do
  @moduledoc """
  Executes tool calls in parallel with supervision and timeout handling.

  The broker resolves tool names from the agent's tool list, optionally
  validates arguments against the tool's schema, then executes each call
  under a `Task.Supervisor`. Individual failures (errors, crashes, timeouts)
  become error `ToolResult`s — the broker itself always succeeds.

  ## Example

      tool_calls = [%ToolCall{id: "1", name: "calculator", arguments: %{"op" => "add", "a" => 1, "b" => 2}}]
      tools = [Agora.Tool.Calculator]

      {:ok, results} = Agora.ToolBroker.execute(tool_calls, tools)
      # => {:ok, [%ToolResult{tool_call_id: "1", content: "3", is_error: false}]}

  """

  alias Agora.{CancelToken, ToolCall, ToolResult, Tool}

  @default_supervisor Agora.ToolSupervisor

  @typedoc """
  A tool entry in the tools list.

  Executable tools are module atoms implementing `Agora.Tool` or
  `%FunctionTool{}` structs. Plain maps are accepted for backward
  compatibility but are not executable — calling them produces an
  error `ToolResult`.
  """
  @type tool_entry :: Tool.tool() | map()

  @doc """
  Executes a list of tool calls in parallel.

  Each call is resolved against the provided tools list, optionally validated,
  and executed under a `Task.Supervisor`. Returns `{:ok, [ToolResult.t()]}` always.

  Timeouts are enforced per-tool using a deadline calculated from when all
  tasks were spawned, so sequential awaiting does not inflate wall-clock time.
  Tasks that exceed their deadline are immediately killed (`:brutal_kill`).

  ## Tools

  The `tools` list accepts module atoms, `%FunctionTool{}` structs, and plain
  maps. Plain maps are resolved by name but are not executable — invoking them
  produces an error result.

  ## Options

    * `:supervisor` - Task.Supervisor name (default: `Agora.ToolSupervisor`)
    * `:validate` - whether to validate arguments against schema (default: `true`)
    * `:context` - context map passed to tool execute (default: `%{}`)

  """
  @spec execute([ToolCall.t()], [tool_entry()], map(), keyword()) :: {:ok, [ToolResult.t()]}
  def execute(tool_calls, tools, context \\ %{}, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, @default_supervisor)
    validate? = Keyword.get(opts, :validate, true)
    cancel_token = Keyword.get(opts, :cancel_token)

    tool_map = build_tool_map(tools)
    start_time = System.monotonic_time(:millisecond)

    tasks =
      Enum.map(tool_calls, fn tool_call ->
        timeout = resolve_timeout(tool_call.name, tool_map)
        meta = %{tool_name: tool_call.name, tool_call_id: tool_call.id}

        Agora.Telemetry.emit(
          [:agora, :tool, :call, :start],
          %{system_time: System.system_time()},
          meta
        )

        if cancel_token do
          # Synchronize spawn and registration: task blocks until parent
          # registers it in the cancel group, closing the race window.
          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              receive do
                :registered -> execute_single(tool_call, tool_map, context, validate?)
              end
            end)

          CancelToken.register(cancel_token, task.pid)
          send(task.pid, :registered)
          {task, tool_call, timeout, meta, System.monotonic_time()}
        else
          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              execute_single(tool_call, tool_map, context, validate?)
            end)

          {task, tool_call, timeout, meta, System.monotonic_time()}
        end
      end)

    results =
      Enum.map(tasks, fn {task, tool_call, timeout, meta, tool_start} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        remaining = max(timeout - elapsed, 0)

        {result, status} =
          case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
            {:ok, result} ->
              {result, if(result.is_error, do: :error, else: :ok)}

            {:exit, reason} ->
              {ToolResult.error(
                 tool_call.id,
                 tool_call.name,
                 "Tool process exited: #{inspect(reason)}"
               ), :exit}

            nil ->
              {ToolResult.error(
                 tool_call.id,
                 tool_call.name,
                 "Tool execution timed out after #{timeout}ms"
               ), :timeout}
          end

        # Unregister tool task from cancel group
        if cancel_token, do: CancelToken.unregister(cancel_token, task.pid)

        Agora.Telemetry.emit(
          [:agora, :tool, :call, :stop],
          %{duration: System.monotonic_time() - tool_start},
          Map.put(meta, :status, status)
        )

        result
      end)

    {:ok, results}
  end

  @doc """
  Executes a single tool call synchronously.

  Resolves the tool, validates arguments (if enabled), executes, and wraps
  the result in a `ToolResult`. Catches exceptions, throws, and exits
  from misbehaving tools.
  """
  @spec execute_single(ToolCall.t(), map(), map(), boolean()) :: ToolResult.t()
  def execute_single(%ToolCall{} = tool_call, tool_map, context, validate?) do
    with {:ok, tool} <- resolve_tool(tool_call.name, tool_map),
         :ok <- maybe_validate(tool_call.arguments, tool, validate?) do
      case Tool.execute(tool, tool_call.arguments, context) do
        {:ok, result} ->
          ToolResult.success(tool_call.id, tool_call.name, result)

        {:error, reason} ->
          ToolResult.error(tool_call.id, tool_call.name, reason)
      end
    else
      {:error, message} when is_binary(message) ->
        ToolResult.error(tool_call.id, tool_call.name, message)
    end
  catch
    kind, reason ->
      Agora.Telemetry.emit(
        [:agora, :tool, :call, :exception],
        %{duration: 0},
        %{
          tool_name: tool_call.name,
          tool_call_id: tool_call.id,
          kind: kind,
          reason: format_catch_reason(kind, reason)
        }
      )

      ToolResult.error(
        tool_call.id,
        tool_call.name,
        format_catch_message(kind, reason)
      )
  end

  defp format_catch_reason(:error, exception) when is_exception(exception),
    do: Exception.message(exception)

  defp format_catch_reason(_kind, reason), do: inspect(reason)

  defp format_catch_message(:exit, reason), do: "Tool exited: #{inspect(reason)}"
  defp format_catch_message(:throw, value), do: "Tool threw: #{inspect(value)}"

  defp format_catch_message(:error, exception) do
    message =
      if is_exception(exception),
        do: Exception.message(exception),
        else: inspect(exception)

    "Tool raised: #{message}"
  end

  defp build_tool_map(tools) do
    Map.new(tools, fn
      mod when is_atom(mod) -> {mod.name(), mod}
      %Agora.Tool.FunctionTool{name: name} = ft -> {name, ft}
      %{"name" => name} = map -> {name, map}
      %{name: name} = map -> {to_string(name), map}
    end)
  end

  defp resolve_tool(name, tool_map) do
    case Map.fetch(tool_map, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, "Unknown tool: #{name}"}
    end
  end

  defp resolve_timeout(name, tool_map) do
    case Map.fetch(tool_map, name) do
      {:ok, tool} -> tool_timeout(tool)
      :error -> 30_000
    end
  end

  defp maybe_validate(_args, _tool, false), do: :ok

  defp maybe_validate(args, tool, true) do
    schema = tool_schema(tool)

    case Agora.Tool.Schema.validate(args, schema) do
      :ok -> :ok
      {:error, errors} -> {:error, "Validation failed: #{Enum.join(errors, "; ")}"}
    end
  end

  defp tool_schema(mod) when is_atom(mod), do: mod.schema()
  defp tool_schema(%Agora.Tool.FunctionTool{schema: schema}), do: schema
  defp tool_schema(%{} = _map), do: %{}

  defp tool_timeout(mod) when is_atom(mod), do: Tool.timeout(mod)
  defp tool_timeout(%Agora.Tool.FunctionTool{} = ft), do: Tool.timeout(ft)
  defp tool_timeout(%{} = _map), do: 30_000
end
