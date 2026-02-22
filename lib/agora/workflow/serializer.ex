defmodule Agora.Workflow.Serializer do
  @moduledoc """
  Serializes workflow topology to JSON-compatible maps.

  Captures the structural (non-executable) parts of a workflow: step metadata,
  edge structure, and workflow hash. Functions (handlers, conditions, input_mappers)
  are represented as type annotations with optional handler references.

  ## Handler Types

  Each step's handler is classified by type:
    * `"function"` — anonymous function or captured function
    * `"agent"` — `%AgentConfig{}` struct
    * `"unknown"` — unrecognized handler type

  ## Round-Trip Serialization

  With a `HandlerRegistry`, handlers can be stored as string references and
  resolved back to executable functions. Without a registry, `handler_ref` is
  `nil` and handlers must be provided via the `:handlers` option when calling
  `WorkflowTopology.to_workflow/2`.

  ## Schema Version

  The current schema version is 1. `from_map/2` rejects maps with a higher
  schema version to prevent loading incompatible future formats.
  """

  alias Agora.{Error, Workflow}
  alias Agora.Workflow.{Checkpoint, WorkflowTopology}

  @schema_version 1

  @doc """
  Serializes a workflow to a JSON-compatible map.

  ## Options

    * `:handler_registry` — `{module, state}` tuple for resolving handler references
    * `:include_hash` — include `workflow_hash` (default: `true`)

  """
  @spec to_map(Workflow.t(), keyword()) :: {:ok, map()}
  def to_map(%Workflow{} = workflow, opts \\ []) do
    include_hash = Keyword.get(opts, :include_hash, true)
    handler_registry = Keyword.get(opts, :handler_registry)

    steps =
      Map.new(workflow.steps, fn {id, step} ->
        handler_type = classify_handler(step.handler)
        handler_ref = resolve_handler_ref(step.handler, handler_registry)

        step_data = %{
          "name" => step.name,
          "inputs" => Enum.map(step.inputs, &to_string/1),
          "outputs" => step.outputs,
          "timeout" => step.timeout,
          "retry" => step.retry,
          "handler_type" => handler_type,
          "handler_ref" => handler_ref
        }

        {to_string(id), step_data}
      end)

    edges =
      Enum.map(workflow.edges, fn edge ->
        %{
          "from" => to_string(edge.from),
          "to" => to_string(edge.to),
          "optional" => edge.optional,
          "has_condition" => edge.condition != nil
        }
      end)

    result = %{
      "_schema_version" => @schema_version,
      "steps" => steps,
      "edges" => edges,
      "metadata" => workflow.metadata
    }

    result =
      if include_hash do
        Map.put(result, "_workflow_hash", Checkpoint.workflow_hash(workflow))
      else
        result
      end

    {:ok, result}
  end

  @doc """
  Deserializes a map to a `%WorkflowTopology{}`.

  Step IDs remain as strings in the returned topology. Atom conversion
  happens at `WorkflowTopology.to_workflow/2` time, where `:known_step_ids`
  and other reconstruction options are accepted.

  The `opts` parameter is reserved for future use (e.g., schema migration)
  and currently has no effect.
  """
  @spec from_map(map(), keyword()) :: {:ok, WorkflowTopology.t()} | {:error, Error.t()}
  def from_map(data, opts \\ [])

  def from_map(%{"_schema_version" => version} = _data, _opts) when version > @schema_version do
    Error.wrap(
      :validation_error,
      "Unsupported schema version #{version} (max supported: #{@schema_version})"
    )
  end

  def from_map(%{} = data, _opts) do
    schema_version = Map.get(data, "_schema_version", 1)
    workflow_hash = Map.get(data, "_workflow_hash")

    steps =
      data
      |> Map.get("steps", %{})
      |> Map.new(fn {id, step_data} ->
        {id,
         %{
           id: id,
           name: Map.get(step_data, "name"),
           inputs: Map.get(step_data, "inputs", []),
           outputs: Map.get(step_data, "outputs"),
           timeout: Map.get(step_data, "timeout", 300_000),
           retry: Map.get(step_data, "retry", 0),
           handler_type: Map.get(step_data, "handler_type", "unknown"),
           handler_ref: Map.get(step_data, "handler_ref")
         }}
      end)

    edges_result =
      data
      |> Map.get("edges", [])
      |> Enum.reduce_while({:ok, []}, fn edge_data, {:ok, acc} ->
        with {:ok, from} <- map_require(edge_data, "from"),
             {:ok, to} <- map_require(edge_data, "to") do
          edge = %{
            from: from,
            to: to,
            optional: Map.get(edge_data, "optional", false),
            has_condition: Map.get(edge_data, "has_condition", false)
          }

          {:cont, {:ok, [edge | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    case edges_result do
      {:ok, edges} ->
        {:ok,
         %WorkflowTopology{
           schema_version: schema_version,
           workflow_hash: workflow_hash,
           steps: steps,
           edges: Enum.reverse(edges),
           metadata: Map.get(data, "metadata", %{})
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Serializes a workflow to a JSON string.
  """
  @spec to_json(Workflow.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_json(%Workflow{} = workflow, opts \\ []) do
    with {:ok, map} <- to_map(workflow, opts) do
      case Jason.encode(map, pretty: true) do
        {:ok, json} -> {:ok, json}
        {:error, reason} -> Error.wrap(:workflow_error, "JSON encode failed: #{inspect(reason)}")
      end
    end
  end

  @doc """
  Deserializes a JSON string to a `%WorkflowTopology{}`.
  """
  @spec from_json(String.t(), keyword()) :: {:ok, WorkflowTopology.t()} | {:error, Error.t()}
  def from_json(json, opts \\ []) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> from_map(data, opts)
      {:error, reason} -> Error.wrap(:workflow_error, "JSON decode failed: #{inspect(reason)}")
    end
  end

  # --- Private ---

  defp classify_handler(handler) when is_function(handler, 1), do: "function"

  defp classify_handler(%Agora.AgentConfig{}), do: "agent"

  defp classify_handler(_), do: "unknown"

  defp resolve_handler_ref(_handler, nil), do: nil

  defp resolve_handler_ref(handler, {module, state}) do
    case module.handler_to_ref(state, handler) do
      {:ok, ref} -> ref
      {:error, _} -> nil
    end
  end

  defp map_require(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Error.wrap(:validation_error, "Missing required key #{inspect(key)} in edge data")
    end
  end

  defp map_require(not_a_map, _key) do
    Error.wrap(:validation_error, "Expected edge to be a map, got: #{inspect(not_a_map)}")
  end
end
