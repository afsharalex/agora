defmodule Agora.Orchestrator.Supervisor do
  @moduledoc """
  Delegation-based orchestrator where a supervisor agent delegates work to workers.

  The supervisor agent receives user input and can delegate to worker agents
  by including a `DELEGATE:worker_name:message` directive in its response.
  Worker results are fed back to the supervisor as `"Worker result: ..."`.

  ## Config

    * `config.agent_names` (required) — all agent names
    * `config.supervisor_agent` (required) — atom name of the supervisor agent
    * `config.parse_delegation` (optional) — custom 2-arity parser function
      `(response_content, worker_lookup) -> {:delegate, atom(), String.t()} | :no_delegation`

  ## Safety

  Parsed worker names are validated against a known worker lookup map.
  `String.to_atom/1` is never called on model output to prevent atom table
  exhaustion.

  ## Default Delegation Format

      DELEGATE:worker_name:message to send to worker

  """

  @behaviour Agora.Orchestrator

  alias Agora.{Error, Message}

  @default_pattern ~r/^DELEGATE:([^:]+):(.+)$/s

  @impl true
  def init(config) do
    case Map.fetch(config, :supervisor_agent) do
      {:ok, supervisor} ->
        do_init(config, supervisor)

      :error ->
        {:error,
         Error.new(
           :orchestration_error,
           "Supervisor orchestrator requires :supervisor_agent in config"
         )}
    end
  end

  defp do_init(config, supervisor) do
    all_agents = Map.get(config, :agent_names, [])
    workers = Enum.reject(all_agents, &(&1 == supervisor))

    worker_lookup =
      Map.new(workers, fn name -> {Atom.to_string(name), name} end)

    parse_fn = Map.get(config, :parse_delegation)

    case validate_parse_delegation(parse_fn) do
      :ok ->
        {:ok,
         %{
           supervisor: supervisor,
           workers: workers,
           worker_lookup: worker_lookup,
           phase: :supervisor,
           last_worker_result: nil,
           delegation_message: nil,
           parse_fn: parse_fn
         }}

      {:error, _} = err ->
        err
    end
  end

  defp validate_parse_delegation(nil), do: :ok
  defp validate_parse_delegation(fun) when is_function(fun, 2), do: :ok

  defp validate_parse_delegation(_),
    do:
      {:error,
       Error.new(
         :orchestration_error,
         ":parse_delegation must be a 2-arity function or nil"
       )}

  @impl true
  def next(%{phase: :supervisor} = state, context) do
    input =
      case state.last_worker_result do
        nil -> context.original_input
        result -> Message.user("Worker result: #{result}")
      end

    {:next, state.supervisor, input, state}
  end

  def next(%{phase: {:worker, worker}} = state, _context) do
    input = Message.user(state.delegation_message)
    {:next, worker, input, state}
  end

  @impl true
  def handle_result(%{phase: :supervisor} = state, _agent, {:ok, msg}) do
    content = msg.content || ""

    case parse_delegation(content, state.worker_lookup, state.parse_fn) do
      {:delegate, worker, message} ->
        {:continue, %{state | phase: {:worker, worker}, delegation_message: message}}

      :no_delegation ->
        {:done, msg, state}

      {:error, error} ->
        {:error, error, state}
    end
  end

  def handle_result(state, _agent, {:ok, msg}) do
    # Worker phase — store result, switch back to supervisor
    content = msg.content || ""

    {:continue,
     %{state | phase: :supervisor, last_worker_result: content, delegation_message: nil}}
  end

  def handle_result(state, _agent, {:error, err}) do
    {:error, err, state}
  end

  defp parse_delegation(content, worker_lookup, nil) do
    default_parse(content, worker_lookup)
  end

  defp parse_delegation(content, worker_lookup, parse_fn) when is_function(parse_fn, 2) do
    parse_fn.(content, worker_lookup)
  end

  defp default_parse(content, worker_lookup) do
    case Regex.run(@default_pattern, content) do
      [_full, name_str, message] ->
        case Map.fetch(worker_lookup, name_str) do
          {:ok, worker_atom} ->
            {:delegate, worker_atom, message}

          :error ->
            {:error,
             Error.new(
               :orchestration_error,
               "Unknown worker agent: #{inspect(name_str)}",
               %{attempted_worker: name_str, known_workers: Map.keys(worker_lookup)}
             )}
        end

      nil ->
        :no_delegation
    end
  end
end
