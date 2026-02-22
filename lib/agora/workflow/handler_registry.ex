defmodule Agora.Workflow.HandlerRegistry do
  @moduledoc """
  Behaviour for resolving handler references to executable functions.

  Enables round-trip workflow serialization: serialized workflows store
  handler reference strings that the registry resolves back to functions
  at load time.

  ## Built-in Registry

  `Agora.Workflow.HandlerRegistry.Default` provides an ETS-backed
  registry added to the application supervision tree.

  ## Handler Reference Conventions

    * Module functions: `"MyApp.Handlers.fetch/1"`
    * Agent configs: `"agent:researcher"` (resolved via config lookup)
    * Custom: any string the registry can resolve

  ## Usage with Serializer

  During serialization (`Serializer.to_map/2`), the registry's
  `handler_to_ref/2` callback maps each handler to a string reference.
  During reconstruction (`WorkflowTopology.to_workflow/2`), the registry's
  `resolve/2` callback maps string references back to handlers.

  The registry is passed as a `{module, state}` tuple, following the
  same dispatch pattern used by `CheckpointStore` and `Memory`.
  """

  alias Agora.Error

  @doc """
  Registers a handler under a string reference.
  """
  @callback register(state :: term(), ref :: String.t(), handler :: term()) ::
              {:ok, state :: term()} | {:error, Error.t()}

  @doc """
  Resolves a string reference to a handler.
  """
  @callback resolve(state :: term(), ref :: String.t()) ::
              {:ok, term()} | {:error, Error.t()}

  @doc """
  Maps a handler to its string reference (reverse lookup).
  """
  @callback handler_to_ref(state :: term(), handler :: term()) ::
              {:ok, String.t()} | {:error, Error.t()}

  @doc """
  Lists all registered handler references and their handlers.
  """
  @callback list(state :: term()) ::
              {:ok, %{String.t() => term()}} | {:error, Error.t()}

  @doc """
  Removes a handler registration.
  """
  @callback unregister(state :: term(), ref :: String.t()) ::
              {:ok, state :: term()} | {:error, Error.t()}
end
