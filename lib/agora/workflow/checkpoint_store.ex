defmodule Agora.Workflow.CheckpointStore do
  @moduledoc """
  Behaviour for checkpoint backends that persist workflow step results.

  Checkpoint stores enable workflow resumability: if a workflow fails partway
  through, previously completed steps can be loaded from the checkpoint and
  skipped on retry.

  ## Callbacks

  Implementations must define five callbacks:

    * `init/1` — Initialize backend state from config options
    * `save/3` — Save a step result by step ID
    * `load/2` — Load a single step result (returns `nil` if not found)
    * `load_all/1` — Load all checkpointed results
    * `clear/1` — Remove all checkpointed results

  ## Dispatch

  The dispatch functions in this module accept `{module, state}` tuples,
  routing to the appropriate backend. The executor uses these dispatch
  functions rather than calling backends directly.

  ## Key Mapping

  Backends store and return keys in their native format (atoms for Memory,
  strings for File). The `load_all/2` dispatch function accepts a list of
  known step IDs from the workflow and maps backend keys to atoms safely.
  Unknown keys (from stale checkpoints or workflow evolution) are silently
  dropped.

  ## Built-in Backends

    * `Agora.Workflow.CheckpointStore.Memory` — In-memory map backend
    * `Agora.Workflow.CheckpointStore.File` — JSON file with atomic writes

  """

  alias Agora.Error

  @doc "Initialize backend state from config options."
  @callback init(config :: keyword()) :: {:ok, state :: term()} | {:error, Error.t()}

  @doc "Save a step result by step ID."
  @callback save(state :: term(), step_id :: atom(), result :: term()) ::
              {:ok, state :: term()} | {:error, Error.t()}

  @doc "Load a single step result. Returns `{:ok, nil}` if not found."
  @callback load(state :: term(), step_id :: atom()) ::
              {:ok, term() | nil} | {:error, Error.t()}

  @doc "Load all checkpointed results."
  @callback load_all(state :: term()) :: {:ok, map()} | {:error, Error.t()}

  @doc "Remove all checkpointed results."
  @callback clear(state :: term()) :: {:ok, state :: term()} | {:error, Error.t()}

  # --- Dispatch functions ---

  @doc """
  Initializes a checkpoint store backend.

  Validates that the module implements all required callbacks, then
  delegates to `module.init/1`.

  Returns `{:ok, {module, state}}` or `{:error, %Error{}}`.
  """
  @spec init({module(), keyword()}) :: {:ok, {module(), term()}} | {:error, Error.t()}
  def init({module, opts}) when is_atom(module) and is_list(opts) do
    with :ok <- validate_module(module),
         {:ok, state} <- safe_call(module, :init, [opts]) do
      {:ok, {module, state}}
    end
  end

  @doc """
  Saves a step result to the checkpoint store.

  Returns `{:ok, {module, new_state}}` or `{:error, %Error{}}`.
  """
  @spec save({module(), term()}, atom(), term()) ::
          {:ok, {module(), term()}} | {:error, Error.t()}
  def save({module, state}, step_id, result) when is_atom(step_id) do
    case safe_call(module, :save, [state, step_id, result]) do
      {:ok, new_state} -> {:ok, {module, new_state}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Loads a single step result from the checkpoint store.

  Returns `{:ok, result | nil}` or `{:error, %Error{}}`.
  """
  @spec load({module(), term()}, atom()) :: {:ok, term() | nil} | {:error, Error.t()}
  def load({module, state}, step_id) when is_atom(step_id) do
    safe_call(module, :load, [state, step_id])
  end

  @doc """
  Loads all checkpointed results, mapping keys to atoms via known step IDs.

  Backend keys are mapped against `known_step_ids`. String keys (from File
  backend) are converted to atoms only if they match a known step ID. Unknown
  keys are silently dropped.

  Returns `{:ok, %{atom() => term()}}` or `{:error, %Error{}}`.
  """
  @spec load_all({module(), term()}, [atom()]) :: {:ok, map()} | {:error, Error.t()}
  def load_all({module, state}, known_step_ids) when is_list(known_step_ids) do
    case safe_call(module, :load_all, [state]) do
      {:ok, raw_map} ->
        lookup = Map.new(known_step_ids, fn id -> {Atom.to_string(id), id} end)
        known_set = MapSet.new(known_step_ids)

        mapped =
          Enum.reduce(raw_map, %{}, fn {k, v}, acc ->
            atom_key = if is_atom(k), do: k, else: Map.get(lookup, k)

            if atom_key && MapSet.member?(known_set, atom_key),
              do: Map.put(acc, atom_key, v),
              else: acc
          end)

        {:ok, mapped}

      error ->
        error
    end
  end

  @doc """
  Clears all checkpointed results.

  Returns `{:ok, {module, new_state}}` or `{:error, %Error{}}`.
  """
  @spec clear({module(), term()}) :: {:ok, {module(), term()}} | {:error, Error.t()}
  def clear({module, state}) do
    case safe_call(module, :clear, [state]) do
      {:ok, new_state} -> {:ok, {module, new_state}}
      {:error, _} = error -> error
    end
  end

  # --- Private ---

  defp safe_call(module, function, args) do
    case apply(module, function, args) do
      {:ok, _} = ok ->
        ok

      {:error, %Error{}} = error ->
        error

      {:error, other} ->
        {:error,
         Error.new(
           :workflow_error,
           "CheckpointStore #{inspect(module)}.#{function} returned non-Error: #{inspect(other)}"
         )}

      other ->
        {:error,
         Error.new(
           :workflow_error,
           "CheckpointStore #{inspect(module)}.#{function} returned unexpected: #{inspect(other)}"
         )}
    end
  rescue
    exception ->
      {:error,
       Error.new(
         :workflow_error,
         "CheckpointStore #{inspect(module)}.#{function} raised: #{Exception.message(exception)}"
       )}
  catch
    kind, value ->
      {:error,
       Error.new(
         :workflow_error,
         "CheckpointStore #{inspect(module)}.#{function} #{kind}: #{inspect(value)}"
       )}
  end

  defp validate_module(module) do
    with {:module, _} <- Code.ensure_loaded(module) do
      callbacks = [init: 1, save: 3, load: 2, load_all: 1, clear: 1]

      if Enum.all?(callbacks, fn {fun, arity} -> function_exported?(module, fun, arity) end) do
        :ok
      else
        {:error,
         Error.new(
           :workflow_error,
           "CheckpointStore module #{inspect(module)} does not implement required callbacks (init/1, save/3, load/2, load_all/1, clear/1)"
         )}
      end
    else
      {:error, reason} ->
        {:error,
         Error.new(
           :workflow_error,
           "CheckpointStore module #{inspect(module)} could not be loaded: #{inspect(reason)}"
         )}
    end
  end
end
