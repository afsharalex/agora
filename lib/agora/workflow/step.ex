defmodule Agora.Workflow.Step do
  @moduledoc """
  A single step in a workflow DAG.

  Steps can use **agent handlers** or **function handlers**:

  - **Agent handler** (`%AgentConfig{}`) — the executor starts a temporary agent,
    runs it with the input derived from upstream results, and stops it. Use
    `Agora.Workflow.AgentStep.spec/3` for ergonomic construction.
  - **Function handler** (`(map() -> {:ok, term()} | {:error, Error.t()})`) —
    a plain function receiving upstream results. Useful for non-LLM computation.

  ## Fields

    * `:id` (required) — unique atom identifying this step
    * `:handler` (required) — `(map() -> {:ok, term()} | {:error, Error.t()})` or `AgentConfig.t()`
    * `:name` — human-readable name (defaults to `to_string(id)`)
    * `:inputs` — list of upstream step IDs this step depends on. The Builder
      auto-generates edges from these declarations.
    * `:outputs` — optional schema map documenting what this step produces.
      The executor does not enforce this; it exists for documentation only.
    * `:input_mapper` — for `AgentConfig` handlers: a `(map() -> String.t() | Message.t())`
      function that converts the upstream results map into a user message.
      When `nil`, a default JSON encoding of successful upstream results is used.
    * `:timeout` — maximum execution time in milliseconds (default: 300_000)
    * `:retry` — number of retry attempts on failure (default: 0)

  """

  alias Agora.{AgentConfig, Error}

  @type handler :: (map() -> {:ok, term()} | {:error, Error.t()}) | AgentConfig.t()
  @type input_mapper :: (map() -> String.t() | Agora.Message.t())

  @type t :: %__MODULE__{
          id: atom(),
          handler: handler(),
          name: String.t() | nil,
          inputs: [atom()],
          outputs: map() | nil,
          input_mapper: input_mapper() | nil,
          timeout: pos_integer(),
          retry: non_neg_integer()
        }

  @derive {Jason.Encoder, except: [:handler, :input_mapper]}
  defstruct [
    :id,
    :handler,
    :name,
    :input_mapper,
    inputs: [],
    outputs: nil,
    timeout: 300_000,
    retry: 0
  ]

  @doc """
  Creates a new Step struct with validation.

  Returns `{:ok, %Step{}}` or `{:error, %Error{}}`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    with {:ok, id} <- validate_id(opts[:id]),
         {:ok, handler} <- validate_handler(opts[:handler]),
         {:ok, inputs} <- validate_inputs(opts[:inputs]),
         {:ok, input_mapper} <- validate_input_mapper(opts[:input_mapper]),
         {:ok, timeout} <- validate_timeout(opts[:timeout]),
         {:ok, retry} <- validate_retry(opts[:retry]) do
      {:ok,
       %__MODULE__{
         id: id,
         handler: handler,
         name: opts[:name] || to_string(id),
         inputs: inputs,
         outputs: opts[:outputs],
         input_mapper: input_mapper,
         timeout: timeout,
         retry: retry
       }}
    end
  end

  @doc """
  Creates a new Step struct, raising on validation failure.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, step} -> step
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  @reserved_ids [:input]

  defp validate_id(nil),
    do: Error.wrap(:workflow_error, "Step :id is required")

  defp validate_id(id) when id in @reserved_ids,
    do: Error.wrap(:workflow_error, "Step :id #{inspect(id)} is reserved and cannot be used")

  defp validate_id(id) when is_atom(id), do: {:ok, id}

  defp validate_id(other),
    do: Error.wrap(:workflow_error, "Step :id must be an atom, got: #{inspect(other)}")

  defp validate_handler(nil),
    do: Error.wrap(:workflow_error, "Step :handler is required")

  defp validate_handler(%AgentConfig{} = config), do: {:ok, config}

  defp validate_handler(fun) when is_function(fun, 1), do: {:ok, fun}

  defp validate_handler(other),
    do:
      Error.wrap(
        :workflow_error,
        "Step :handler must be a 1-arity function or AgentConfig, got: #{inspect(other)}"
      )

  defp validate_inputs(nil), do: {:ok, []}

  defp validate_inputs(inputs) when is_list(inputs) do
    if Enum.all?(inputs, &is_atom/1) do
      {:ok, inputs}
    else
      Error.wrap(:workflow_error, "Step :inputs must be a list of atoms")
    end
  end

  defp validate_inputs(other),
    do: Error.wrap(:workflow_error, "Step :inputs must be a list, got: #{inspect(other)}")

  defp validate_input_mapper(nil), do: {:ok, nil}

  defp validate_input_mapper(fun) when is_function(fun, 1), do: {:ok, fun}

  defp validate_input_mapper(other),
    do:
      Error.wrap(
        :workflow_error,
        "Step :input_mapper must be a 1-arity function, got: #{inspect(other)}"
      )

  defp validate_timeout(nil), do: {:ok, 300_000}

  defp validate_timeout(t) when is_integer(t) and t > 0, do: {:ok, t}

  defp validate_timeout(other),
    do:
      Error.wrap(
        :workflow_error,
        "Step :timeout must be a positive integer, got: #{inspect(other)}"
      )

  defp validate_retry(nil), do: {:ok, 0}

  defp validate_retry(r) when is_integer(r) and r >= 0, do: {:ok, r}

  defp validate_retry(other),
    do:
      Error.wrap(
        :workflow_error,
        "Step :retry must be a non-negative integer, got: #{inspect(other)}"
      )
end
