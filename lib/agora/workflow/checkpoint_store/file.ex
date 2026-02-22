defmodule Agora.Workflow.CheckpointStore.File do
  @moduledoc """
  JSON file-backed checkpoint backend with atomic writes.

  Supports two modes:

  ## Legacy mode (`:path`)

  Persists step results as a JSON object on disk. Writes use a temp-file +
  rename pattern for crash safety (no partial writes). Keys are serialized
  as strings via `Atom.to_string/1`.

  Each file path should map to exactly one workflow. Different workflows
  must use different file paths to avoid checkpoint collision.

  ## Snapshot mode (`:dir`)

  Enables append-only checkpoint snapshots with directory-based storage.
  Each checkpoint ID gets its own subdirectory with versioned JSON files
  and advisory lock support.

      checkpoint_dir/
      ├── chk_abc123/
      │   ├── v001.json
      │   ├── v002.json
      │   └── .lock
      └── chk_def456/
          └── v001.json

  ## Configuration

    * `:path` — file path for legacy JSON storage (`String.t()`)
    * `:dir` — directory path for snapshot storage (`String.t()`)
    * `:namespace` — optional string prefix for keys (legacy mode only)
    * `:lock_timeout` — stale lock timeout in seconds (default: 300)

  `:path` and `:dir` are mutually exclusive.

  ## Examples

      # Legacy mode
      checkpoint_store: {Agora.Workflow.CheckpointStore.File, path: "/tmp/checkpoint.json"}

      # Snapshot mode
      checkpoint_store: {Agora.Workflow.CheckpointStore.File, dir: "/tmp/checkpoints"}

  """

  @behaviour Agora.Workflow.CheckpointStore

  alias Agora.Error
  alias Agora.Workflow.Checkpoint

  @default_lock_timeout 300

  @impl true
  def init(opts) do
    has_path = Keyword.has_key?(opts, :path)
    has_dir = Keyword.has_key?(opts, :dir)

    cond do
      has_path and has_dir ->
        Error.wrap(:workflow_error, ":path and :dir are mutually exclusive")

      has_dir ->
        init_dir_mode(opts)

      has_path ->
        init_path_mode(opts)

      true ->
        Error.wrap(:workflow_error, ":path or :dir is required for File checkpoint backend")
    end
  end

  defp init_path_mode(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) ->
        namespace = Keyword.get(opts, :namespace)
        state = %{mode: :path, path: path, namespace: namespace}

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
        Error.wrap(:workflow_error, ":path or :dir is required for File checkpoint backend")
    end
  end

  defp init_dir_mode(opts) do
    case Keyword.fetch(opts, :dir) do
      {:ok, dir} when is_binary(dir) ->
        lock_timeout = Keyword.get(opts, :lock_timeout, @default_lock_timeout)

        case File.mkdir_p(dir) do
          :ok ->
            {:ok, %{mode: :dir, dir: dir, lock_timeout: lock_timeout}}

          {:error, reason} ->
            Error.wrap(:workflow_error, "Failed to create directory #{dir}: #{inspect(reason)}")
        end

      {:ok, invalid} ->
        Error.wrap(:workflow_error, ":dir must be a string, got: #{inspect(invalid)}")

      :error ->
        Error.wrap(:workflow_error, ":path or :dir is required for File checkpoint backend")
    end
  end

  # --- Required callbacks ---

  @impl true
  def save(%{mode: :dir} = state, _step_id, _result) do
    # Dir mode uses save_snapshot for persistence; per-step save is a no-op.
    {:ok, state}
  end

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
  def load(%{mode: :dir} = _state, _step_id) do
    # Dir mode uses load_snapshot; per-step load returns nil.
    {:ok, nil}
  end

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
  def load_all(%{mode: :dir} = _state) do
    # Dir mode uses load_snapshot; load_all returns empty.
    {:ok, %{}}
  end

  def load_all(state) do
    case read_data(state.path) do
      {:ok, data} ->
        prefix = if state[:namespace], do: "#{state.namespace}:", else: nil

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

  def clear(%{namespace: ns} = state) when is_binary(ns) do
    prefix = "#{ns}:"

    case read_data(state.path) do
      {:ok, data} when data == %{} ->
        {:ok, state}

      {:ok, data} ->
        filtered = Map.reject(data, fn {k, _v} -> String.starts_with?(k, prefix) end)

        if filtered == data do
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

  def clear(%{mode: :dir} = state) do
    case File.rm_rf(state.dir) do
      {:ok, _} ->
        File.mkdir_p(state.dir)
        {:ok, state}

      {:error, reason, _} ->
        Error.wrap(:workflow_error, "Failed to clear #{state.dir}: #{inspect(reason)}")
    end
  end

  # --- Optional snapshot callbacks ---

  # Path-mode guards: snapshot APIs require :dir mode
  @impl true
  def save_snapshot(%{mode: :path} = _state, %Checkpoint{}) do
    Error.wrap(
      :config_error,
      "Snapshot APIs require :dir mode; this store was configured with :path"
    )
  end

  @impl true
  def save_snapshot(%{mode: :dir} = state, %Checkpoint{} = checkpoint) do
    checkpoint_dir = Path.join(state.dir, checkpoint.id)

    with :ok <- File.mkdir_p(checkpoint_dir) do
      version_file = Path.join(checkpoint_dir, version_filename(checkpoint.version))
      data = serialize_checkpoint(checkpoint)

      case write_data(version_file, data) do
        :ok -> {:ok, state}
        {:error, _} = error -> error
      end
    else
      {:error, reason} ->
        Error.wrap(:workflow_error, "Failed to create checkpoint dir: #{inspect(reason)}")
    end
  end

  @impl true
  def load_snapshot(%{mode: :path} = _state, _checkpoint_id, _version) do
    {:ok, nil}
  end

  @impl true
  def load_snapshot(%{mode: :dir} = state, checkpoint_id, version) do
    checkpoint_dir = Path.join(state.dir, checkpoint_id)

    case version do
      :latest ->
        load_latest_snapshot(checkpoint_dir)

      v when is_integer(v) and v > 0 ->
        version_file = Path.join(checkpoint_dir, version_filename(v))

        case File.read(version_file) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, data} ->
                {:ok, deserialize_checkpoint(data)}

              {:error, reason} ->
                Error.wrap(:workflow_error, "JSON decode failed: #{inspect(reason)}")
            end

          {:error, :enoent} ->
            {:ok, nil}

          {:error, reason} ->
            Error.wrap(:workflow_error, "Failed to read snapshot: #{inspect(reason)}")
        end
    end
  end

  @impl true
  def list_snapshots(%{mode: :path} = _state) do
    {:ok, []}
  end

  @impl true
  def list_snapshots(%{mode: :dir} = state) do
    case File.ls(state.dir) do
      {:ok, entries} ->
        checkpoints =
          entries
          |> Enum.filter(fn entry ->
            Path.join(state.dir, entry) |> File.dir?()
          end)
          |> Enum.flat_map(fn id ->
            checkpoint_dir = Path.join(state.dir, id)

            case load_latest_snapshot(checkpoint_dir) do
              {:ok, nil} -> []
              {:ok, checkpoint} -> [checkpoint]
              {:error, _} -> []
            end
          end)

        {:ok, checkpoints}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        Error.wrap(:workflow_error, "Failed to list snapshots: #{inspect(reason)}")
    end
  end

  @impl true
  def delete_snapshot(%{mode: :path} = _state, _checkpoint_id, _version) do
    Error.wrap(
      :config_error,
      "Snapshot APIs require :dir mode; this store was configured with :path"
    )
  end

  @impl true
  def delete_snapshot(%{mode: :dir} = state, checkpoint_id, version) do
    checkpoint_dir = Path.join(state.dir, checkpoint_id)
    version_file = Path.join(checkpoint_dir, version_filename(version))

    case File.rm(version_file) do
      :ok ->
        {:ok, state}

      {:error, :enoent} ->
        {:ok, state}

      {:error, reason} ->
        Error.wrap(:workflow_error, "Failed to delete snapshot: #{inspect(reason)}")
    end
  end

  @impl true
  def lock(%{mode: :path} = state, _checkpoint_id) do
    {:ok, state}
  end

  @impl true
  def lock(%{mode: :dir} = state, checkpoint_id) do
    checkpoint_dir = Path.join(state.dir, checkpoint_id)
    lock_file = Path.join(checkpoint_dir, ".lock")

    with :ok <- File.mkdir_p(checkpoint_dir) do
      # Atomic exclusive create — avoids TOCTOU race between stat and write.
      case :file.open(lock_file, [:write, :exclusive]) do
        {:ok, fd} ->
          lock_data =
            Jason.encode!(%{
              "pid" => inspect(self()),
              "locked_at" => DateTime.to_iso8601(DateTime.utc_now())
            })

          :file.write(fd, lock_data)
          :file.close(fd)
          {:ok, state}

        {:error, :eexist} ->
          # Lock file exists — check if stale
          handle_existing_lock(lock_file, state, checkpoint_id)

        {:error, reason} ->
          Error.wrap(:workflow_error, "Failed to acquire lock: #{inspect(reason)}")
      end
    end
  end

  @impl true
  def unlock(%{mode: :path} = state, _checkpoint_id) do
    {:ok, state}
  end

  @impl true
  def unlock(%{mode: :dir} = state, checkpoint_id) do
    checkpoint_dir = Path.join(state.dir, checkpoint_id)
    lock_file = Path.join(checkpoint_dir, ".lock")

    case File.rm(lock_file) do
      :ok -> {:ok, state}
      {:error, :enoent} -> {:ok, state}
      {:error, reason} -> Error.wrap(:workflow_error, "Failed to unlock: #{inspect(reason)}")
    end
  end

  # --- Private ---

  # --- Snapshot helpers ---

  defp version_filename(version) do
    "v" <> String.pad_leading(to_string(version), 3, "0") <> ".json"
  end

  defp parse_version_number(filename) do
    case Regex.run(~r/^v(\d+)\.json$/, filename) do
      [_, num] -> String.to_integer(num)
      _ -> 0
    end
  end

  defp load_latest_snapshot(checkpoint_dir) do
    case File.ls(checkpoint_dir) do
      {:ok, files} ->
        version_files =
          files
          |> Enum.filter(&String.match?(&1, ~r/^v\d+\.json$/))
          |> Enum.sort_by(&parse_version_number/1, :desc)

        case version_files do
          [latest_file | _] ->
            path = Path.join(checkpoint_dir, latest_file)

            case File.read(path) do
              {:ok, content} ->
                case Jason.decode(content) do
                  {:ok, data} ->
                    {:ok, deserialize_checkpoint(data)}

                  {:error, reason} ->
                    Error.wrap(:workflow_error, "JSON decode failed: #{inspect(reason)}")
                end

              {:error, reason} ->
                Error.wrap(:workflow_error, "Failed to read snapshot: #{inspect(reason)}")
            end

          [] ->
            {:ok, nil}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        Error.wrap(:workflow_error, "Failed to list versions: #{inspect(reason)}")
    end
  end

  defp serialize_checkpoint(%Checkpoint{} = checkpoint) do
    %{
      "_schema_version" => 1,
      "id" => checkpoint.id,
      "workflow_hash" => checkpoint.workflow_hash,
      "version" => checkpoint.version,
      "status" => to_string(checkpoint.status),
      "created_at" => DateTime.to_iso8601(checkpoint.created_at),
      "updated_at" => DateTime.to_iso8601(checkpoint.updated_at),
      "otp_major_version" => checkpoint.otp_major_version,
      "completed_steps" => Enum.map(checkpoint.completed_steps, &to_string/1),
      "pending_steps" => Enum.map(checkpoint.pending_steps, &to_string/1),
      "failed_steps" => Enum.map(checkpoint.failed_steps, &to_string/1),
      "results" =>
        Map.new(checkpoint.results, fn {k, v} ->
          {to_string(k), serialize_result(v)}
        end),
      "metadata" => checkpoint.metadata
    }
  end

  @valid_statuses MapSet.new(~w(in_progress completed failed abandoned))

  defp deserialize_checkpoint(data) do
    status_string = Map.get(data, "status", "in_progress")

    status =
      if MapSet.member?(@valid_statuses, status_string),
        do: String.to_existing_atom(status_string),
        else: :in_progress

    results =
      data
      |> Map.get("results", %{})
      |> Map.new(fn {k, v} -> {safe_to_existing_atom(k), deserialize_result(v)} end)
      |> Enum.reject(fn {k, _} -> is_nil(k) end)
      |> Map.new()

    %Checkpoint{
      id: data["id"],
      workflow_hash: data["workflow_hash"],
      version: data["version"] || 1,
      status: status,
      results: results,
      completed_steps: data |> Map.get("completed_steps", []) |> safe_to_atom_set(),
      pending_steps: data |> Map.get("pending_steps", []) |> safe_to_atom_set(),
      failed_steps: data |> Map.get("failed_steps", []) |> safe_to_atom_set(),
      created_at: parse_datetime(data["created_at"]),
      updated_at: parse_datetime(data["updated_at"]),
      otp_major_version: data["otp_major_version"],
      metadata: Map.get(data, "metadata", %{})
    }
  end

  defp safe_to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_atom_set(list) when is_list(list) do
    list
    |> Enum.map(&safe_to_existing_atom/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp handle_existing_lock(lock_file, state, checkpoint_id) do
    case File.stat(lock_file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        age = System.os_time(:second) - mtime

        if age > state.lock_timeout do
          # Stale lock — remove and retry exclusive create
          File.rm(lock_file)

          case :file.open(lock_file, [:write, :exclusive]) do
            {:ok, fd} ->
              lock_data =
                Jason.encode!(%{
                  "pid" => inspect(self()),
                  "locked_at" => DateTime.to_iso8601(DateTime.utc_now())
                })

              :file.write(fd, lock_data)
              :file.close(fd)
              {:ok, state}

            {:error, :eexist} ->
              # Another process grabbed it between rm and open — genuinely locked
              Error.wrap(:workflow_error, "Checkpoint #{checkpoint_id} is locked")

            {:error, reason} ->
              Error.wrap(:workflow_error, "Failed to acquire lock: #{inspect(reason)}")
          end
        else
          Error.wrap(:workflow_error, "Checkpoint #{checkpoint_id} is locked")
        end

      {:error, :enoent} ->
        # Lock file disappeared between open and stat — retry
        lock(state, checkpoint_id)

      {:error, reason} ->
        Error.wrap(:workflow_error, "Failed to check lock: #{inspect(reason)}")
    end
  end

  # --- Result serialization ---
  # Step results are `{:ok, value} | {:error, Error.t()} | :skipped`
  # which need explicit encoding for JSON.

  @valid_error_type_strings MapSet.new(Enum.map(Error.valid_types(), &to_string/1))

  defp serialize_result({:ok, value}), do: %{"_status" => "ok", "value" => value}

  defp serialize_result({:error, %Error{} = error}) do
    base = %{
      "_status" => "error",
      "type" => to_string(error.type),
      "message" => error.message
    }

    if error.metadata == %{} do
      base
    else
      Map.put(base, "metadata", serialize_metadata(error.metadata))
    end
  end

  defp serialize_result(:skipped), do: %{"_status" => "skipped"}
  defp serialize_result(other), do: other

  defp deserialize_result(%{"_status" => "ok", "value" => value}), do: {:ok, value}

  defp deserialize_result(%{"_status" => "error", "type" => type, "message" => message} = raw) do
    metadata = Map.get(raw, "metadata", %{})

    error_type =
      if MapSet.member?(@valid_error_type_strings, type),
        do: String.to_existing_atom(type),
        else: :workflow_error

    {:error, Error.new(error_type, message, metadata)}
  end

  defp deserialize_result(%{"_status" => "skipped"}), do: :skipped
  defp deserialize_result(other), do: other

  defp serialize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {k, v} ->
      key = if is_atom(k), do: to_string(k), else: k
      {key, serialize_metadata_value(v)}
    end)
  end

  defp serialize_metadata_value(v)
       when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
       do: v

  defp serialize_metadata_value(v) when is_atom(v), do: to_string(v)
  defp serialize_metadata_value(v) when is_list(v), do: Enum.map(v, &serialize_metadata_value/1)
  defp serialize_metadata_value(v) when is_map(v), do: serialize_metadata(v)
  defp serialize_metadata_value(v), do: inspect(v)

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
