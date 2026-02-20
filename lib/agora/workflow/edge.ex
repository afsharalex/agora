defmodule Agora.Workflow.Edge do
  @moduledoc """
  A directed edge in a workflow DAG.

  Connects a source step to a target step. An optional condition function
  controls whether the edge is active at execution time.

  ## Fields

    * `:from` (required) — source step ID (atom)
    * `:to` (required) — target step ID (atom)
    * `:condition` — optional 1-arity function `(map() -> boolean())` that
      receives the current results map and returns whether this edge is active.
      When `nil`, the edge is unconditional.

  """

  alias Agora.Error

  @type t :: %__MODULE__{
          from: atom(),
          to: atom(),
          condition: (map() -> boolean()) | nil
        }

  @derive {Jason.Encoder, except: [:condition]}
  defstruct [:from, :to, :condition]

  @doc """
  Creates a new Edge struct with validation.

  Returns `{:ok, %Edge{}}` or `{:error, %Error{}}`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    with {:ok, from} <- validate_endpoint(opts[:from], :from),
         {:ok, to} <- validate_endpoint(opts[:to], :to),
         {:ok, condition} <- validate_condition(opts[:condition]),
         :ok <- validate_no_self_loop(from, to) do
      {:ok, %__MODULE__{from: from, to: to, condition: condition}}
    end
  end

  @doc """
  Creates a new Edge struct, raising on validation failure.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, edge} -> edge
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  defp validate_endpoint(nil, field),
    do: Error.wrap(:workflow_error, "Edge :#{field} is required")

  defp validate_endpoint(id, _field) when is_atom(id), do: {:ok, id}

  defp validate_endpoint(other, field),
    do: Error.wrap(:workflow_error, "Edge :#{field} must be an atom, got: #{inspect(other)}")

  defp validate_condition(nil), do: {:ok, nil}

  defp validate_condition(fun) when is_function(fun, 1), do: {:ok, fun}

  defp validate_condition(other),
    do:
      Error.wrap(
        :workflow_error,
        "Edge :condition must be a 1-arity function, got: #{inspect(other)}"
      )

  defp validate_no_self_loop(id, id),
    do:
      Error.wrap(:workflow_error, "Edge cannot be a self-loop: #{inspect(id)} -> #{inspect(id)}")

  defp validate_no_self_loop(_from, _to), do: :ok
end
