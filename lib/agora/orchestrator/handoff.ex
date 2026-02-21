defmodule Agora.Orchestrator.Handoff do
  @moduledoc """
  Decentralized baton-passing orchestrator where agents decide who runs next.

  Each agent can hand off control to another agent by emitting a handoff
  directive in its response. An agent that returns without a handoff directive
  is declaring the task done — its response becomes the final result.

  ## Handoff Mechanisms (in priority order)

  1. **Metadata handoff** — `Message.new(:assistant, content, metadata: %{handoff: %{target: "agent", message: "context"}})`
  2. **Custom parser** — configured via `:parse_handoff` option (fully overrides default directive)
  3. **Default directive** — `HANDOFF:agent_name:message to pass`

  If metadata handoff is present but malformed, the orchestrator errors immediately
  (no fallback to directive parsing). This surfaces programming errors clearly.

  When a custom parser is configured, it fully overrides default directive parsing —
  no fallback to the default regex if the parser returns `:no_handoff`.

  ## Config

    * `config.agent_names` (required) — all agent names
    * `config.initial_agent` (required) — atom name of the first agent to run

  ## Orchestrator Options (via `:orchestrator_opts`)

    * `:initial_agent` (required) — atom name of the first agent to receive input
    * `:max_hops` — maximum handoffs before error (default: 10, must be positive)
    * `:no_repeat_window` — sliding window size to prevent recent agent repeats (default: nil/disabled)
    * `:allowed_handoff_targets` — `%{source_agent => [allowed_targets]}` map (default: nil/all allowed except self).
      An agent not present as a key in the map cannot hand off — this is **fail-closed** behavior.
    * `:parse_handoff` — custom 2-arity parser function (default: nil)

  ## Safety

    * Self-handoff is blocked by default (unless explicitly listed in `:allowed_handoff_targets`)
    * Parsed agent names are validated against a known lookup map — `String.to_atom/1` is never called on model output
    * `no_repeat_window` prevents recent agent repeats; when disabled (`nil`), loops are bounded only by `:max_hops`

  ## Custom Parser Contract

      (String.t(), %{String.t() => atom()}) ->
        {:handoff, atom(), String.t()} | :no_handoff | {:error, Error.t()}

  ## Default Directive Format

      HANDOFF:agent_name:message to pass to the next agent

  The directive must appear at the very start of the response content (no leading
  whitespace or prose). Use metadata handoff for responses that include other content
  alongside the handoff instruction.

  """

  @behaviour Agora.Orchestrator

  alias Agora.{Error, Message}

  @default_pattern ~r/^HANDOFF:([^:]+):(.+)$/s

  @impl true
  def init(config) do
    with {:ok, initial_agent} <- validate_initial_agent(config),
         {:ok, agents} <- build_agents(config, initial_agent),
         {:ok, agent_lookup} <- build_agent_lookup(agents),
         {:ok, max_hops} <- validate_max_hops(config),
         {:ok, no_repeat_window} <- validate_no_repeat_window(config),
         {:ok, allowed_targets} <- validate_allowed_targets(config, agents),
         {:ok, parse_fn} <- validate_parse_handoff(config) do
      {:ok,
       %{
         initial_agent: initial_agent,
         current_agent: initial_agent,
         agents: agents,
         agent_lookup: agent_lookup,
         handoff_history: [initial_agent],
         hop_count: 0,
         max_hops: max_hops,
         no_repeat_window: no_repeat_window,
         allowed_targets: allowed_targets,
         handoff_message: nil,
         parse_fn: parse_fn
       }}
    end
  end

  @impl true
  def next(state, context) do
    input =
      case state.handoff_message do
        nil -> context.original_input
        message -> Message.user(message)
      end

    {:next, state.current_agent, input, state}
  end

  @impl true
  def handle_result(state, _agent, {:ok, msg}) do
    case parse_handoff(msg, state.agent_lookup, state.parse_fn) do
      {:handoff, target, message} ->
        validate_and_execute_handoff(target, message, state)

      :no_handoff ->
        {:done, msg, state}

      {:error, error} ->
        {:error, error, state}
    end
  end

  def handle_result(state, _agent, {:error, err}) do
    {:error, err, state}
  end

  # --- Private: Initialization ---

  defp validate_initial_agent(config) do
    case Map.fetch(config, :initial_agent) do
      {:ok, agent} when is_atom(agent) ->
        agent_names = Map.get(config, :agent_names, [])

        if agent in agent_names do
          {:ok, agent}
        else
          {:error,
           Error.new(
             :orchestration_error,
             ":initial_agent #{inspect(agent)} is not in agent_names",
             %{initial_agent: agent, agent_names: agent_names}
           )}
        end

      {:ok, other} ->
        {:error,
         Error.new(
           :orchestration_error,
           ":initial_agent must be an atom, got: #{inspect(other)}"
         )}

      :error ->
        {:error,
         Error.new(
           :orchestration_error,
           "Handoff orchestrator requires :initial_agent in config"
         )}
    end
  end

  defp build_agents(config, _initial_agent) do
    agents = config |> Map.get(:agent_names, []) |> Enum.sort()
    {:ok, agents}
  end

  defp build_agent_lookup(agents) do
    lookup = Map.new(agents, fn name -> {Atom.to_string(name), name} end)
    {:ok, lookup}
  end

  defp validate_max_hops(config) do
    case Map.get(config, :max_hops, 10) do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      other ->
        {:error,
         Error.new(
           :orchestration_error,
           ":max_hops must be a positive integer, got: #{inspect(other)}"
         )}
    end
  end

  defp validate_no_repeat_window(config) do
    case Map.get(config, :no_repeat_window) do
      nil ->
        {:ok, nil}

      n when is_integer(n) and n > 0 ->
        {:ok, n}

      other ->
        {:error,
         Error.new(
           :orchestration_error,
           ":no_repeat_window must be a positive integer or nil, got: #{inspect(other)}"
         )}
    end
  end

  defp validate_allowed_targets(config, agents) do
    case Map.get(config, :allowed_handoff_targets) do
      nil ->
        {:ok, nil}

      targets when is_map(targets) ->
        agent_set = MapSet.new(agents)

        with :ok <- validate_target_keys(targets, agent_set),
             :ok <- validate_target_values(targets, agent_set) do
          {:ok, targets}
        end

      other ->
        {:error,
         Error.new(
           :orchestration_error,
           ":allowed_handoff_targets must be a map or nil, got: #{inspect(other)}"
         )}
    end
  end

  defp validate_target_keys(targets, agent_set) do
    unknown = targets |> Map.keys() |> Enum.reject(&MapSet.member?(agent_set, &1))

    case unknown do
      [] ->
        :ok

      keys ->
        {:error,
         Error.new(
           :orchestration_error,
           "Unknown agent(s) in :allowed_handoff_targets keys: #{inspect(keys)}"
         )}
    end
  end

  defp validate_target_values(targets, agent_set) do
    invalid =
      Enum.flat_map(targets, fn {source, allowed} ->
        if is_list(allowed) do
          unknown = Enum.reject(allowed, &MapSet.member?(agent_set, &1))
          Enum.map(unknown, fn t -> {source, t} end)
        else
          [{source, :not_a_list}]
        end
      end)

    case invalid do
      [] ->
        :ok

      [{_source, :not_a_list} | _] ->
        {:error,
         Error.new(
           :orchestration_error,
           ":allowed_handoff_targets values must be lists of agent atoms"
         )}

      pairs ->
        unknowns = Enum.map(pairs, fn {_s, t} -> t end)

        {:error,
         Error.new(
           :orchestration_error,
           "Unknown agent(s) in :allowed_handoff_targets values: #{inspect(unknowns)}"
         )}
    end
  end

  defp validate_parse_handoff(config) do
    case Map.get(config, :parse_handoff) do
      nil -> {:ok, nil}
      fun when is_function(fun, 2) -> {:ok, fun}
      fun when is_function(fun) ->
        {:error,
         Error.new(
           :orchestration_error,
           ":parse_handoff must be a 2-arity function, got function with arity #{Function.info(fun)[:arity]}"
         )}
      other ->
        {:error,
         Error.new(
           :orchestration_error,
           ":parse_handoff must be a 2-arity function or nil, got: #{inspect(other)}"
         )}
    end
  end

  # --- Private: Handoff parsing ---

  defp parse_handoff(msg, agent_lookup, parse_fn) do
    case extract_metadata_handoff(msg, agent_lookup) do
      {:handoff, _target, _message} = result -> result
      {:error, _} = err -> err
      :no_metadata -> parse_content(msg.content || "", agent_lookup, parse_fn)
    end
  end

  defp extract_metadata_handoff(msg, agent_lookup) do
    case Map.get(msg.metadata || %{}, :handoff) do
      nil ->
        :no_metadata

      %{target: target} = handoff when is_binary(target) ->
        with {:ok, agent_atom} <- resolve_metadata_target(target, agent_lookup, :string),
             {:ok, message} <- validate_metadata_message(handoff, msg.content) do
          {:handoff, agent_atom, message}
        end

      %{target: target} = handoff when is_atom(target) ->
        with {:ok, agent_atom} <- resolve_metadata_target(target, agent_lookup, :atom),
             {:ok, message} <- validate_metadata_message(handoff, msg.content) do
          {:handoff, agent_atom, message}
        end

      %{} ->
        {:error,
         Error.new(
           :orchestration_error,
           "Malformed handoff metadata: missing :target key"
         )}

      other ->
        {:error,
         Error.new(
           :orchestration_error,
           "Malformed handoff metadata: expected a map, got: #{inspect(other)}"
         )}
    end
  end

  defp resolve_metadata_target(target, agent_lookup, :string) do
    case Map.fetch(agent_lookup, target) do
      {:ok, agent_atom} ->
        {:ok, agent_atom}

      :error ->
        {:error,
         Error.new(
           :orchestration_error,
           "Unknown handoff target in metadata: #{inspect(target)}",
           %{attempted_target: target, known_agents: Map.keys(agent_lookup)}
         )}
    end
  end

  defp resolve_metadata_target(target, agent_lookup, :atom) do
    if target in Map.values(agent_lookup) do
      {:ok, target}
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Unknown handoff target in metadata: #{inspect(target)}",
         %{attempted_target: target, known_agents: Map.values(agent_lookup)}
       )}
    end
  end

  defp validate_metadata_message(handoff, fallback_content) do
    message = Map.get(handoff, :message, fallback_content)

    case message do
      nil -> {:ok, ""}
      msg when is_binary(msg) -> {:ok, msg}
      other ->
        {:error,
         Error.new(
           :orchestration_error,
           "Malformed handoff metadata: :message must be a string or nil, got: #{inspect(other)}"
         )}
    end
  end

  defp parse_content(content, agent_lookup, nil) do
    default_parse(content, agent_lookup)
  end

  defp parse_content(content, agent_lookup, parse_fn) do
    case safe_parse(fn -> parse_fn.(content, agent_lookup) end) do
      {:handoff, target, message} ->
        validate_parsed_target(target, message, agent_lookup)

      other ->
        other
    end
  end

  defp default_parse(content, agent_lookup) do
    case Regex.run(@default_pattern, content) do
      [_full, name_str, message] ->
        case Map.fetch(agent_lookup, name_str) do
          {:ok, agent_atom} ->
            {:handoff, agent_atom, message}

          :error ->
            {:error,
             Error.new(
               :orchestration_error,
               "Unknown handoff target in directive: #{inspect(name_str)}",
               %{attempted_target: name_str, known_agents: Map.keys(agent_lookup)}
             )}
        end

      nil ->
        :no_handoff
    end
  end

  defp safe_parse(parse_fn) do
    result = parse_fn.()
    validate_parse_result(result)
  catch
    kind, reason ->
      {:error,
       Error.new(
         :orchestration_error,
         "Custom parse_handoff crashed: #{format_crash(kind, reason)}"
       )}
  end

  defp validate_parse_result({:handoff, target, message})
       when is_atom(target) and is_binary(message) do
    {:handoff, target, message}
  end

  defp validate_parse_result({:handoff, _target, message}) when not is_binary(message) do
    {:error,
     Error.new(
       :orchestration_error,
       "Custom parse_handoff returned non-binary message: #{inspect(message)}"
     )}
  end

  defp validate_parse_result(:no_handoff), do: :no_handoff

  defp validate_parse_result({:error, %Error{}} = result), do: result

  defp validate_parse_result(other) do
    {:error,
     Error.new(
       :orchestration_error,
       "Custom parse_handoff returned invalid shape: #{inspect(other)}"
     )}
  end

  defp validate_parsed_target(target, message, agent_lookup) do
    if target in Map.values(agent_lookup) do
      {:handoff, target, message}
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Custom parse_handoff returned unknown target: #{inspect(target)}",
         %{attempted_target: target, known_agents: Map.values(agent_lookup)}
       )}
    end
  end

  defp format_crash(:error, %{__exception__: true} = exception),
    do: Exception.message(exception)

  defp format_crash(:error, reason), do: inspect(reason)
  defp format_crash(:exit, reason), do: "exit: #{inspect(reason)}"
  defp format_crash(:throw, value), do: "throw: #{inspect(value)}"

  # --- Private: Handoff validation and execution ---

  defp validate_and_execute_handoff(target, message, state) do
    with :ok <- check_self_handoff(target, state),
         :ok <- check_max_hops(state),
         :ok <- check_allowed_target(target, state),
         :ok <- check_no_repeat_window(target, state) do
      events = [%{type: :handoff, from: state.current_agent, to: target, message: normalize_message(message)}]

      {:continue,
       %{
         state
         | current_agent: target,
           handoff_message: normalize_message(message),
           hop_count: state.hop_count + 1,
           handoff_history: state.handoff_history ++ [target]
       }, events}
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp check_self_handoff(target, %{allowed_targets: nil, current_agent: current})
       when target == current do
    {:error,
     Error.new(
       :orchestration_error,
       "Self-handoff not allowed: #{inspect(target)} cannot hand off to itself",
       %{agent: target}
     )}
  end

  defp check_self_handoff(_target, %{allowed_targets: nil}), do: :ok

  # When allowed_targets is a map, self-handoff is handled by check_allowed_target
  defp check_self_handoff(_target, _state), do: :ok

  defp check_max_hops(%{hop_count: hop_count, max_hops: max_hops} = state)
       when hop_count >= max_hops do
    {:error,
     Error.new(
       :orchestration_error,
       "Max hops (#{max_hops}) exceeded",
       %{hop_count: hop_count, max_hops: max_hops, history: state.handoff_history}
     )}
  end

  defp check_max_hops(_state), do: :ok

  defp check_allowed_target(target, %{allowed_targets: nil, agent_lookup: agent_lookup}) do
    if target in Map.values(agent_lookup) do
      :ok
    else
      {:error,
       Error.new(
         :orchestration_error,
         "Unknown handoff target: #{inspect(target)}",
         %{attempted_target: target, known_agents: Map.values(agent_lookup)}
       )}
    end
  end

  defp check_allowed_target(target, %{allowed_targets: targets, current_agent: current}) do
    case Map.fetch(targets, current) do
      {:ok, allowed} ->
        if target in allowed do
          :ok
        else
          {:error,
           Error.new(
             :orchestration_error,
             "Handoff from #{inspect(current)} to #{inspect(target)} not allowed by policy",
             %{source: current, target: target, allowed: allowed}
           )}
        end

      :error ->
        {:error,
         Error.new(
           :orchestration_error,
           "Agent #{inspect(current)} is not permitted to hand off (not in allowed_handoff_targets keys)",
           %{source: current, allowed_sources: Map.keys(targets)}
         )}
    end
  end

  defp check_no_repeat_window(_target, %{no_repeat_window: nil}), do: :ok

  defp check_no_repeat_window(target, %{no_repeat_window: window, handoff_history: history}) do
    recent = Enum.take(history, -window)

    if target in recent do
      {:error,
       Error.new(
         :orchestration_error,
         "Handoff to #{inspect(target)} blocked by no_repeat_window (window=#{window})",
         %{target: target, window: window, recent_agents: recent}
       )}
    else
      :ok
    end
  end

  defp normalize_message(nil), do: ""
  defp normalize_message(msg) when is_binary(msg), do: msg
end
