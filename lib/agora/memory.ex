defmodule Agora.Memory do
  @moduledoc """
  Behaviour for memory backends that persist agent conversation history.

  Memory backends enable agents to bound conversation growth (via ring buffers)
  and persist history across process restarts (via file storage).

  ## Callbacks

  Implementations must define four callbacks:

    * `init/1` — Initialize backend state from config options
    * `get/1` — Retrieve stored messages (excludes system messages)
    * `save/2` — Atomically replace all stored messages
    * `clear/1` — Remove all stored messages

  ## Dispatch

  The dispatch functions in this module accept `{module, state}` tuples,
  routing to the appropriate backend. Agent integration uses these
  dispatch functions rather than calling backends directly.

  ## Built-in Backends

    * `Agora.Memory.Buffer` — In-memory ring buffer with bounded size
    * `Agora.Memory.File` — JSON file persistence with atomic writes

  """

  alias Agora.{Error, Message}

  @doc "Initialize backend state from config options."
  @callback init(config :: keyword()) :: {:ok, state :: term()} | {:error, Error.t()}

  @doc "Retrieve all stored messages in chronological order."
  @callback get(state :: term()) :: {:ok, [Message.t()]} | {:error, Error.t()}

  @doc "Atomically replace all stored messages."
  @callback save(state :: term(), messages :: [Message.t()]) ::
              {:ok, state :: term()} | {:error, Error.t()}

  @doc "Remove all stored messages."
  @callback clear(state :: term()) :: {:ok, state :: term()} | {:error, Error.t()}

  @doc """
  Initializes a memory backend.

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
  Retrieves stored messages from the backend.

  Returns `{:ok, [Message.t()]}` or `{:error, %Error{}}`.
  """
  @spec get({module(), term()}) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def get({module, state}) do
    safe_call(module, :get, [state])
  end

  @doc """
  Atomically saves messages to the backend, replacing all previous content.

  Returns `{:ok, {module, new_state}}` or `{:error, %Error{}}`.
  """
  @spec save({module(), term()}, [Message.t()]) ::
          {:ok, {module(), term()}} | {:error, Error.t()}
  def save({module, state}, messages) when is_list(messages) do
    case safe_call(module, :save, [state, messages]) do
      {:ok, new_state} -> {:ok, {module, new_state}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Clears all stored messages from the backend.

  Returns `{:ok, {module, new_state}}` or `{:error, %Error{}}`.
  """
  @spec clear({module(), term()}) :: {:ok, {module(), term()}} | {:error, Error.t()}
  def clear({module, state}) do
    case safe_call(module, :clear, [state]) do
      {:ok, new_state} -> {:ok, {module, new_state}}
      {:error, _} = error -> error
    end
  end

  defp safe_call(module, function, args) do
    case apply(module, function, args) do
      {:ok, _} = ok ->
        ok

      {:error, %Error{}} = error ->
        error

      {:error, other} ->
        {:error,
         Error.new(
           :memory_error,
           "Memory backend #{inspect(module)}.#{function} returned non-Error: #{inspect(other)}"
         )}

      other ->
        {:error,
         Error.new(
           :memory_error,
           "Memory backend #{inspect(module)}.#{function} returned unexpected: #{inspect(other)}"
         )}
    end
  rescue
    exception ->
      {:error,
       Error.new(
         :memory_error,
         "Memory backend #{inspect(module)}.#{function} raised: #{Exception.message(exception)}"
       )}
  catch
    kind, value ->
      {:error,
       Error.new(
         :memory_error,
         "Memory backend #{inspect(module)}.#{function} #{kind}: #{inspect(value)}"
       )}
  end

  defp validate_module(module) do
    with {:module, _} <- Code.ensure_loaded(module) do
      callbacks = [init: 1, get: 1, save: 2, clear: 1]

      if Enum.all?(callbacks, fn {fun, arity} -> function_exported?(module, fun, arity) end) do
        :ok
      else
        {:error,
         Error.new(
           :memory_error,
           "Memory module #{inspect(module)} does not implement required callbacks (init/1, get/1, save/2, clear/1)"
         )}
      end
    else
      {:error, reason} ->
        {:error,
         Error.new(
           :memory_error,
           "Memory module #{inspect(module)} could not be loaded: #{inspect(reason)}"
         )}
    end
  end
end
