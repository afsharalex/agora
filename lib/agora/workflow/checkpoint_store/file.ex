defmodule Agora.Workflow.CheckpointStore.File do
  @moduledoc """
  JSON file-backed checkpoint backend with atomic writes.

  Persists step results as a JSON object on disk. Writes use a temp-file +
  rename pattern for crash safety (no partial writes). Keys are serialized
  as strings via `Atom.to_string/1`.

  ## Single-workflow assumption

  Each file path should map to exactly one workflow. Different workflows
  must use different file paths to avoid checkpoint collision.

  ## Configuration

    * `:path` (required) — file path for JSON storage (`String.t()`)
    * `:namespace` — optional string prefix for keys, for advanced use cases
      where multiple workflows share a single file

  ## Example

      checkpoint_store: {Agora.Workflow.CheckpointStore.File, path: "/tmp/workflow_checkpoint.json"}

  """

  @behaviour Agora.Workflow.CheckpointStore

  alias Agora.Error

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) ->
        namespace = Keyword.get(opts, :namespace)
        state = %{path: path, namespace: namespace}

        case File.read(path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, %{}} ->
                {:ok, state}

              {:ok, _} ->
                Error.wrap(:workflow_error, "Expected JSON object in #{path}")

              {:error, reason} ->
                Error.wrap(:workflow_error, "JSON decode failed: #{inspect(reason)}")
            end

          {:error, :enoent} ->
            {:ok, state}

          {:error, reason} ->
            Error.wrap(:workflow_error, "Failed to read #{path}: #{inspect(reason)}")
        end

      {:ok, invalid} ->
        Error.wrap(:workflow_error, ":path must be a string, got: #{inspect(invalid)}")

      :error ->
        Error.wrap(:workflow_error, ":path is required for File checkpoint backend")
    end
  end

  @impl true
  def save(state, step_id, result) do
    key = prefixed_key(state, step_id)

    case read_data(state.path) do
      {:ok, data} ->
        new_data = Map.put(data, key, serialize_result(result))

        case write_data(state.path, new_data) do
          :ok -> {:ok, state}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def load(state, step_id) do
    key = prefixed_key(state, step_id)

    case read_data(state.path) do
      {:ok, data} ->
        case Map.get(data, key) do
          nil -> {:ok, nil}
          raw -> {:ok, deserialize_result(raw)}
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def load_all(state) do
    case read_data(state.path) do
      {:ok, data} ->
        prefix = if state.namespace, do: "#{state.namespace}:", else: nil

        filtered =
          if prefix do
            data
            |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)
            |> Map.new(fn {k, v} ->
              {String.replace_prefix(k, prefix, ""), deserialize_result(v)}
            end)
          else
            Map.new(data, fn {k, v} -> {k, deserialize_result(v)} end)
          end

        {:ok, filtered}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def clear(%{namespace: nil} = state) do
    case File.rm(state.path) do
      :ok ->
        {:ok, state}

      {:error, :enoent} ->
        {:ok, state}

      {:error, reason} ->
        Error.wrap(:workflow_error, "Failed to delete #{state.path}: #{inspect(reason)}")
    end
  end

  def clear(%{namespace: ns} = state) do
    prefix = "#{ns}:"

    case read_data(state.path) do
      {:ok, data} when data == %{} ->
        {:ok, state}

      {:ok, data} ->
        filtered = Map.reject(data, fn {k, _v} -> String.starts_with?(k, prefix) end)

        if filtered == data do
          # Nothing to remove
          {:ok, state}
        else
          case write_data(state.path, filtered) do
            :ok -> {:ok, state}
            {:error, _} = error -> error
          end
        end

      {:error, _} = error ->
        error
    end
  end

  # --- Private ---

  # --- Result serialization ---
  # Step results are `{:ok, value} | {:error, Error.t()} | :skipped`
  # which need explicit encoding for JSON.

  defp serialize_result({:ok, value}), do: %{"_status" => "ok", "value" => value}

  defp serialize_result({:error, %Error{} = error}),
    do: %{"_status" => "error", "type" => to_string(error.type), "message" => error.message}

  defp serialize_result(:skipped), do: %{"_status" => "skipped"}
  defp serialize_result(other), do: other

  defp deserialize_result(%{"_status" => "ok", "value" => value}), do: {:ok, value}

  defp deserialize_result(%{"_status" => "error", "type" => type, "message" => message}),
    do: {:error, Error.new(:workflow_error, "#{type}: #{message}")}

  defp deserialize_result(%{"_status" => "skipped"}), do: :skipped
  defp deserialize_result(other), do: other

  defp prefixed_key(%{namespace: nil}, step_id), do: Atom.to_string(step_id)
  defp prefixed_key(%{namespace: ns}, step_id), do: "#{ns}:#{Atom.to_string(step_id)}"

  defp read_data(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = data} ->
            {:ok, data}

          {:ok, _} ->
            Error.wrap(:workflow_error, "Expected JSON object in #{path}")

          {:error, reason} ->
            Error.wrap(:workflow_error, "JSON decode failed: #{inspect(reason)}")
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        Error.wrap(:workflow_error, "Failed to read #{path}: #{inspect(reason)}")
    end
  end

  defp write_data(path, data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> atomic_write(path, json)
      {:error, reason} -> Error.wrap(:workflow_error, "JSON encode failed: #{inspect(reason)}")
    end
  end

  defp atomic_write(path, data) do
    tmp_path = path <> ".tmp." <> random_suffix()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, data),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        Error.wrap(:workflow_error, "Failed to write #{path}: #{inspect(reason)}")
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
