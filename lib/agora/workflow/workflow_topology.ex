defmodule Agora.Workflow.WorkflowTopology do
  @moduledoc """
  Non-executable structural representation of a workflow.

  Contains step metadata, edge structure, and workflow metadata but NOT
  executable handlers or conditions. Use `to_workflow/2` with a handler
  map to reconstruct an executable `%Workflow{}`.

  ## Atom Safety

  Step IDs are stored as strings internally. They are converted to atoms
  only at `to_workflow/2` time via `String.to_existing_atom/1` with an
  optional allowlist. This prevents atom table exhaustion from untrusted JSON.
  """

  alias Agora.{Error, Workflow}
  alias Agora.Workflow.Builder

  @type step_info :: %{
          id: String.t(),
          name: String.t() | nil,
          inputs: [String.t()],
          outputs: map() | nil,
          timeout: pos_integer(),
          retry: non_neg_integer(),
          handler_type: String.t(),
          handler_ref: String.t() | nil
        }

  @type edge_info :: %{
          from: String.t(),
          to: String.t(),
          optional: boolean(),
          has_condition: boolean()
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          workflow_hash: String.t() | nil,
          steps: %{String.t() => step_info()},
          edges: [edge_info()],
          metadata: map()
        }

  defstruct [
    :workflow_hash,
    schema_version: 1,
    steps: %{},
    edges: [],
    metadata: %{}
  ]

  @doc """
  Reconstructs an executable `%Workflow{}` from this topology.

  Requires a handler map keyed by atom step IDs. Each step in the topology
  must have a corresponding handler.

  ## Options

    * `:handler_registry` — `{module, state}` for resolving `handler_ref` strings
    * `:handlers` — `%{atom() => handler}` fallback map for unresolved refs
    * `:conditions` — `%{{atom(), atom()} => condition_fn}` for edge conditions
    * `:known_step_ids` — list of known atom step IDs for safe string-to-atom conversion

  """
  @spec to_workflow(t(), keyword()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def to_workflow(%__MODULE__{} = topology, opts \\ []) do
    handler_map = Keyword.get(opts, :handlers, %{})
    handler_registry = Keyword.get(opts, :handler_registry)
    conditions = Keyword.get(opts, :conditions, %{})
    known_step_ids = Keyword.get(opts, :known_step_ids)

    with {:ok, atom_step_map} <- convert_step_ids(topology.steps, known_step_ids),
         {:ok, resolved_handlers} <-
           resolve_handlers(topology.steps, handler_map, handler_registry, atom_step_map) do
      build_workflow(topology, atom_step_map, resolved_handlers, conditions)
    end
  end

  @doc """
  Reconstructs an executable `%Workflow{}`, raising on failure.
  """
  @spec to_workflow!(t(), keyword()) :: Workflow.t()
  def to_workflow!(%__MODULE__{} = topology, opts \\ []) do
    case to_workflow(topology, opts) do
      {:ok, workflow} -> workflow
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  # --- Private ---

  defp convert_step_ids(steps, known_step_ids) do
    known_set = if known_step_ids, do: MapSet.new(known_step_ids), else: nil

    result =
      Enum.reduce_while(steps, {:ok, %{}}, fn {string_id, _step_info}, {:ok, acc} ->
        case string_to_safe_atom(string_id, known_set) do
          {:ok, atom_id} -> {:cont, {:ok, Map.put(acc, string_id, atom_id)}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    result
  end

  defp string_to_safe_atom(string, nil) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError ->
      Error.wrap(:validation_error, "Unknown step ID atom: #{inspect(string)}")
  end

  defp string_to_safe_atom(string, known_set) do
    # First check allowlist, then convert
    atom =
      try do
        String.to_existing_atom(string)
      rescue
        ArgumentError -> nil
      end

    if atom && MapSet.member?(known_set, atom) do
      {:ok, atom}
    else
      Error.wrap(:validation_error, "Step ID #{inspect(string)} not in known_step_ids allowlist")
    end
  end

  defp resolve_handlers(steps, handler_map, handler_registry, atom_step_map) do
    Enum.reduce_while(steps, {:ok, %{}}, fn {string_id, step_info}, {:ok, acc} ->
      case Map.fetch(atom_step_map, string_id) do
        {:ok, atom_id} ->
          case resolve_single_handler(step_info, atom_id, handler_map, handler_registry) do
            {:ok, handler} -> {:cont, {:ok, Map.put(acc, atom_id, handler)}}
            {:error, _} = error -> {:halt, error}
          end

        :error ->
          {:halt, Error.wrap(:validation_error, "Step ID #{inspect(string_id)} not in atom map")}
      end
    end)
  end

  defp resolve_single_handler(step_info, atom_id, handler_map, handler_registry) do
    # Try handler_ref via registry first, fall back to handler map
    case {step_info.handler_ref, handler_registry} do
      {ref, {module, state}} when is_binary(ref) ->
        case module.resolve(state, ref) do
          {:ok, _} = success ->
            success

          {:error, _} ->
            # Registry resolve failed — fall back to handler map
            resolve_from_handler_map(handler_map, atom_id)
        end

      _ ->
        resolve_from_handler_map(handler_map, atom_id)
    end
  end

  defp resolve_from_handler_map(handler_map, atom_id) do
    case Map.fetch(handler_map, atom_id) do
      {:ok, handler} -> {:ok, handler}
      :error -> Error.wrap(:validation_error, "No handler for step #{inspect(atom_id)}")
    end
  end

  defp build_workflow(topology, atom_step_map, resolved_handlers, conditions) do
    with {:ok, builder} <- build_steps(topology, atom_step_map, resolved_handlers),
         {:ok, builder} <- build_edges(topology, atom_step_map, conditions, builder) do
      Builder.build(builder)
    end
  end

  defp build_steps(topology, atom_step_map, resolved_handlers) do
    Enum.reduce_while(topology.steps, {:ok, Builder.new()}, fn {string_id, step_info}, {:ok, b} ->
      case {Map.fetch(atom_step_map, string_id),
            Map.fetch(resolved_handlers, Map.get(atom_step_map, string_id))} do
        {{:ok, atom_id}, {:ok, handler}} ->
          case resolve_inputs(step_info.inputs, atom_step_map, string_id) do
            {:ok, inputs} ->
              opts = [
                name: step_info.name,
                inputs: inputs,
                outputs: step_info.outputs,
                timeout: step_info.timeout,
                retry: step_info.retry
              ]

              {:cont, {:ok, Builder.step(b, atom_id, handler, opts)}}

            {:error, _} = error ->
              {:halt, error}
          end

        _ ->
          {:halt,
           Error.wrap(
             :validation_error,
             "Step #{inspect(string_id)} has no atom mapping or resolved handler"
           )}
      end
    end)
  end

  defp build_edges(topology, atom_step_map, conditions, builder) do
    Enum.reduce_while(topology.edges, {:ok, builder}, fn edge_info, {:ok, b} ->
      case {Map.fetch(atom_step_map, edge_info.from), Map.fetch(atom_step_map, edge_info.to)} do
        {{:ok, from_atom}, {:ok, to_atom}} ->
          edge_opts = [optional: edge_info.optional]

          edge_opts =
            if edge_info.has_condition do
              case Map.fetch(conditions, {from_atom, to_atom}) do
                {:ok, condition_fn} -> Keyword.put(edge_opts, :condition, condition_fn)
                :error -> edge_opts
              end
            else
              edge_opts
            end

          {:cont, {:ok, Builder.edge(b, from_atom, to_atom, edge_opts)}}

        _ ->
          {:halt,
           Error.wrap(
             :validation_error,
             "Edge #{inspect(edge_info.from)} -> #{inspect(edge_info.to)} references unknown step ID"
           )}
      end
    end)
  end

  defp resolve_inputs(input_strings, atom_step_map, step_id) do
    Enum.reduce_while(input_strings, {:ok, []}, fn input_str, {:ok, acc} ->
      case Map.fetch(atom_step_map, input_str) do
        {:ok, atom} ->
          {:cont, {:ok, [atom | acc]}}

        :error ->
          {:halt,
           Error.wrap(
             :validation_error,
             "Step #{inspect(step_id)} references unknown input #{inspect(input_str)}"
           )}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      {:error, _} = error -> error
    end
  end
end
