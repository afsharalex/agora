defmodule Agora.Tool.Schema do
  @moduledoc """
  Builders and lightweight validation for JSON Schema maps.

  All builder functions return maps with string keys suitable for
  JSON encoding and consumption by LLM providers.

  ## Builders

      iex> Agora.Tool.Schema.string(description: "A search query")
      %{"type" => "string", "description" => "A search query"}

      iex> Agora.Tool.Schema.object(%{
      ...>   "name" => Agora.Tool.Schema.string(),
      ...>   "age" => Agora.Tool.Schema.integer()
      ...> }, required: ["name"])
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name"]
      }

  ## Validation

  `validate/2` performs lightweight type checking against a schema map.
  It checks types, required fields, enum membership, and recurses into
  nested objects and arrays.
  """

  @doc "Builds a string schema."
  @spec string(keyword()) :: map()
  def string(opts \\ []) do
    %{"type" => "string"}
    |> maybe_add_description(opts)
    |> maybe_add_enum(opts)
  end

  @doc "Builds an integer schema."
  @spec integer(keyword()) :: map()
  def integer(opts \\ []) do
    %{"type" => "integer"}
    |> maybe_add_description(opts)
  end

  @doc "Builds a number schema."
  @spec number(keyword()) :: map()
  def number(opts \\ []) do
    %{"type" => "number"}
    |> maybe_add_description(opts)
  end

  @doc "Builds a boolean schema."
  @spec boolean(keyword()) :: map()
  def boolean(opts \\ []) do
    %{"type" => "boolean"}
    |> maybe_add_description(opts)
  end

  @doc "Builds an array schema with items type."
  @spec array(map(), keyword()) :: map()
  def array(items_schema, opts \\ []) do
    %{"type" => "array", "items" => items_schema}
    |> maybe_add_description(opts)
  end

  @doc """
  Builds an object schema with properties.

  ## Options

    * `:required` - list of required property name strings
    * `:description` - description of the object

  """
  @spec object(map(), keyword()) :: map()
  def object(properties, opts \\ []) do
    schema = %{"type" => "object", "properties" => properties}

    schema =
      case Keyword.get(opts, :required) do
        nil -> schema
        required when is_list(required) -> Map.put(schema, "required", required)
      end

    maybe_add_description(schema, opts)
  end

  @doc """
  Builds a string enum schema.

  ## Examples

      iex> Agora.Tool.Schema.enum(["add", "subtract"])
      %{"type" => "string", "enum" => ["add", "subtract"]}

  """
  @spec enum([String.t()], keyword()) :: map()
  def enum(values, opts \\ []) when is_list(values) do
    %{"type" => "string", "enum" => values}
    |> maybe_add_description(opts)
  end

  @doc """
  Adds required field constraints to an existing object schema.

  This is a convenience wrapper equivalent to passing `required: [...]`
  to `object/2`, useful for pipelines or when adding required fields
  after initial construction.

  ## Examples

      iex> schema = Agora.Tool.Schema.object(%{"name" => Agora.Tool.Schema.string()})
      iex> Agora.Tool.Schema.required(schema, ["name"])
      %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}

  """
  @spec required(map(), [String.t()]) :: map()
  def required(%{"type" => "object"} = schema, fields) when is_list(fields) do
    Map.put(schema, "required", fields)
  end

  @doc """
  Validates arguments against a JSON Schema map.

  Returns `:ok` if valid or `{:error, errors}` with a list of
  human-readable error message strings.

  ## Examples

      iex> schema = Agora.Tool.Schema.object(%{"name" => Agora.Tool.Schema.string()}, required: ["name"])
      iex> Agora.Tool.Schema.validate(%{"name" => "Alice"}, schema)
      :ok
      iex> Agora.Tool.Schema.validate(%{}, schema)
      {:error, ["missing required field: name"]}

  """
  @spec validate(map(), map()) :: :ok | {:error, [String.t()]}
  def validate(args, schema) when is_map(args) and is_map(schema) do
    case do_validate(args, schema, []) do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  # Root object validation
  defp do_validate(args, %{"type" => "object", "properties" => props} = schema, errors) do
    errors = validate_required(args, schema, errors)

    Enum.reduce(props, errors, fn {key, prop_schema}, acc ->
      case Map.fetch(args, key) do
        {:ok, value} -> validate_value(value, prop_schema, [key], acc)
        :error -> acc
      end
    end)
  end

  # Non-object schemas at root: just validate the args map exists
  defp do_validate(_args, _schema, errors), do: errors

  defp validate_required(args, %{"required" => required}, errors) do
    Enum.reduce(required, errors, fn field, acc ->
      if Map.has_key?(args, field) do
        acc
      else
        ["missing required field: #{field}" | acc]
      end
    end)
  end

  defp validate_required(_args, _schema, errors), do: errors

  defp validate_value(value, %{"type" => "string", "enum" => allowed} = _schema, path, errors) do
    cond do
      not is_binary(value) ->
        [format_error(path, "expected string, got #{inspect(value)}") | errors]

      value not in allowed ->
        [
          format_error(path, "expected one of #{inspect(allowed)}, got #{inspect(value)}")
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_value(value, %{"type" => "string"}, path, errors) do
    if is_binary(value) do
      errors
    else
      [format_error(path, "expected string, got #{inspect(value)}") | errors]
    end
  end

  defp validate_value(value, %{"type" => "integer"}, path, errors) do
    if is_integer(value) do
      errors
    else
      [format_error(path, "expected integer, got #{inspect(value)}") | errors]
    end
  end

  defp validate_value(value, %{"type" => "number"}, path, errors) do
    if is_number(value) do
      errors
    else
      [format_error(path, "expected number, got #{inspect(value)}") | errors]
    end
  end

  defp validate_value(value, %{"type" => "boolean"}, path, errors) do
    if is_boolean(value) do
      errors
    else
      [format_error(path, "expected boolean, got #{inspect(value)}") | errors]
    end
  end

  defp validate_value(value, %{"type" => "array", "items" => items_schema}, path, errors) do
    if is_list(value) do
      value
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {item, idx}, acc ->
        validate_value(item, items_schema, path ++ [to_string(idx)], acc)
      end)
    else
      [format_error(path, "expected array, got #{inspect(value)}") | errors]
    end
  end

  defp validate_value(value, %{"type" => "object", "properties" => props} = schema, path, errors) do
    if is_map(value) do
      errors = validate_nested_required(value, schema, path, errors)

      Enum.reduce(props, errors, fn {key, prop_schema}, acc ->
        case Map.fetch(value, key) do
          {:ok, v} -> validate_value(v, prop_schema, path ++ [key], acc)
          :error -> acc
        end
      end)
    else
      [format_error(path, "expected object, got #{inspect(value)}") | errors]
    end
  end

  # Unknown schema type — pass through
  defp validate_value(_value, _schema, _path, errors), do: errors

  defp validate_nested_required(value, %{"required" => required}, path, errors) do
    Enum.reduce(required, errors, fn field, acc ->
      if Map.has_key?(value, field) do
        acc
      else
        [format_error(path ++ [field], "missing required field: #{field}") | acc]
      end
    end)
  end

  defp validate_nested_required(_value, _schema, _path, errors), do: errors

  defp format_error(path, message), do: "#{Enum.join(path, ".")}: #{message}"

  defp maybe_add_description(schema, opts) do
    case Keyword.get(opts, :description) do
      nil -> schema
      desc -> Map.put(schema, "description", desc)
    end
  end

  defp maybe_add_enum(schema, opts) do
    case Keyword.get(opts, :enum) do
      nil -> schema
      values -> Map.put(schema, "enum", values)
    end
  end
end
