defmodule Agora.Tool.FunctionTool do
  @moduledoc """
  Inline tool definition wrapping a plain function.

  Use this when you want to define a tool without creating a dedicated module.
  The function must be a 2-arity function accepting `(args, context)`.

  ## Example

      {:ok, tool} = Agora.Tool.FunctionTool.new(
        name: "greet",
        description: "Greets a person by name",
        schema: Agora.Tool.Schema.object(%{
          "name" => Agora.Tool.Schema.string()
        }, required: ["name"]),
        function: fn %{"name" => name}, _ctx -> {:ok, "Hello, \#{name}!"} end
      )

  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: map(),
          function: (map(), map() -> {:ok, any()} | {:error, any()}),
          timeout: pos_integer()
        }

  @derive {Jason.Encoder, except: [:function]}
  defstruct [:name, :description, :schema, :function, timeout: 30_000]

  @doc """
  Creates a new FunctionTool from a keyword list.

  ## Required Keys

    * `:name` - tool name (string)
    * `:description` - tool description (string)
    * `:schema` - JSON Schema map for arguments
    * `:function` - 2-arity function `(args, context) -> {:ok, any()} | {:error, any()}`

  ## Optional Keys

    * `:timeout` - timeout in milliseconds (default: 30_000)

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Agora.Error.t()}
  def new(opts) when is_list(opts) do
    with :ok <- validate_required(opts),
         :ok <- validate_types(opts) do
      {:ok, struct!(__MODULE__, opts)}
    end
  end

  @doc """
  Creates a new FunctionTool, raising on invalid input.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, ft} -> ft
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  defp validate_required(opts) do
    missing =
      [:name, :description, :schema, :function]
      |> Enum.filter(fn key -> Keyword.get(opts, key) == nil end)

    case missing do
      [] ->
        :ok

      fields ->
        {:error,
         Agora.Error.new(:validation_error, "missing required fields: #{inspect(fields)}")}
    end
  end

  defp validate_types(opts) do
    errors =
      []
      |> check_type(opts, :name, &is_binary/1, "string")
      |> check_type(opts, :description, &is_binary/1, "string")
      |> check_type(opts, :schema, &is_map/1, "map")
      |> check_type(opts, :function, &is_function(&1, 2), "2-arity function")
      |> check_optional_type(opts, :timeout, &(is_integer(&1) and &1 > 0), "positive integer")

    case errors do
      [] ->
        :ok

      errs ->
        {:error, Agora.Error.new(:validation_error, "invalid fields: #{Enum.join(errs, ", ")}")}
    end
  end

  defp check_type(errors, opts, key, validator, expected) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if validator.(value), do: errors, else: ["#{key} must be a #{expected}" | errors]

      :error ->
        errors
    end
  end

  defp check_optional_type(errors, opts, key, validator, expected) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if validator.(value), do: errors, else: ["#{key} must be a #{expected}" | errors]

      :error ->
        errors
    end
  end
end
