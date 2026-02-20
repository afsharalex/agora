defmodule Agora.Memory.File do
  @moduledoc """
  JSON file-backed memory backend with atomic writes.

  Persists messages as a JSON array on disk. Writes use a temp-file +
  rename pattern for crash safety (no partial writes).

  State contains only the file path — no cached messages (reads always
  hit disk to avoid triple duplication).

  ## Single-writer assumption

  This backend assumes a single agent process writes to each file path.
  Within one agent, the GenServer serializes all calls so no concurrent
  write protection is needed. However, **if multiple agents share the
  same file path**, they can overwrite each other's data without warning.
  Use a unique file path per agent to avoid data loss.

  ## Configuration

    * `:path` (required) — file path for JSON storage (`String.t()`)

  ## Example

      config = AgentConfig.new!(
        provider: :echo,
        model: "echo",
        memory: {Agora.Memory.File, path: "/tmp/agent_history.json"}
      )

  """

  @behaviour Agora.Memory

  alias Agora.{Error, Message, ToolCall, ToolResult}

  @valid_roles %{"system" => :system, "user" => :user, "assistant" => :assistant, "tool" => :tool}
  @valid_statuses %{
    "pending" => :pending,
    "running" => :running,
    "completed" => :completed,
    "failed" => :failed
  }

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) ->
        state = %{path: path}

        case File.read(path) do
          {:ok, content} ->
            case deserialize(content) do
              {:ok, _messages} -> {:ok, state}
              {:error, _} = error -> error
            end

          {:error, :enoent} ->
            {:ok, state}

          {:error, reason} ->
            Error.wrap(:memory_error, "Failed to read #{path}: #{inspect(reason)}")
        end

      {:ok, invalid} ->
        Error.wrap(:memory_error, ":path must be a string, got: #{inspect(invalid)}")

      :error ->
        Error.wrap(:memory_error, ":path is required for File memory backend")
    end
  end

  @impl true
  def get(%{path: path}) do
    case File.read(path) do
      {:ok, content} -> deserialize(content)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> Error.wrap(:memory_error, "Failed to read #{path}: #{inspect(reason)}")
    end
  end

  @impl true
  def save(%{path: path} = state, messages) do
    case serialize(messages) do
      {:ok, json} ->
        case atomic_write(path, json) do
          :ok -> {:ok, state}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def clear(%{path: path} = state) do
    case File.rm(path) do
      :ok ->
        {:ok, state}

      {:error, :enoent} ->
        {:ok, state}

      {:error, reason} ->
        Error.wrap(:memory_error, "Failed to delete #{path}: #{inspect(reason)}")
    end
  end

  # --- Atomic write ---

  defp atomic_write(path, data) do
    tmp_path = path <> ".tmp." <> random_suffix()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, data),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        Error.wrap(:memory_error, "Failed to write #{path}: #{inspect(reason)}")
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  # --- Serialization ---

  defp serialize(messages) do
    data = Enum.map(messages, &serialize_message/1)

    case Jason.encode(data, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> Error.wrap(:memory_error, "JSON encode failed: #{inspect(reason)}")
    end
  end

  defp serialize_message(%Message{} = msg) do
    map = %{
      "role" => to_string(msg.role),
      "content" => msg.content,
      "tool_calls" => Enum.map(msg.tool_calls, &serialize_tool_call/1),
      "tool_results" => Enum.map(msg.tool_results, &serialize_tool_result/1),
      "metadata" => msg.metadata,
      "created_at" => if(msg.created_at, do: DateTime.to_iso8601(msg.created_at), else: nil)
    }

    map
  end

  defp serialize_tool_call(%ToolCall{} = tc) do
    %{
      "id" => tc.id,
      "name" => tc.name,
      "arguments" => tc.arguments,
      "status" => to_string(tc.status)
    }
  end

  defp serialize_tool_result(%ToolResult{} = tr) do
    %{
      "tool_call_id" => tr.tool_call_id,
      "name" => tr.name,
      "content" => tr.content,
      "is_error" => tr.is_error
    }
  end

  # --- Deserialization ---

  defp deserialize(content) do
    case Jason.decode(content) do
      {:ok, list} when is_list(list) ->
        deserialize_messages(list, [])

      {:ok, _other} ->
        Error.wrap(:memory_error, "Expected JSON array, got non-array value")

      {:error, reason} ->
        Error.wrap(:memory_error, "JSON decode failed: #{inspect(reason)}")
    end
  end

  defp deserialize_messages([], acc), do: {:ok, Enum.reverse(acc)}

  defp deserialize_messages([raw | rest], acc) do
    case deserialize_message(raw) do
      {:ok, msg} -> deserialize_messages(rest, [msg | acc])
      {:error, _} = error -> error
    end
  end

  defp deserialize_message(map) when is_map(map) do
    with {:ok, role} <- lookup_role(map["role"]),
         {:ok, tool_calls} <- deserialize_tool_calls(map["tool_calls"]),
         {:ok, tool_results} <- deserialize_tool_results(map["tool_results"]),
         {:ok, created_at} <- parse_datetime(map["created_at"]),
         {:ok, metadata} <- validate_metadata(map["metadata"]) do
      msg = %Message{
        role: role,
        content: map["content"],
        tool_calls: tool_calls,
        tool_results: tool_results,
        metadata: metadata,
        created_at: created_at
      }

      {:ok, msg}
    end
  end

  defp deserialize_message(_),
    do: Error.wrap(:memory_error, "Expected message to be a JSON object")

  defp lookup_role(role) when is_binary(role) do
    case Map.fetch(@valid_roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> Error.wrap(:memory_error, "Unknown message role: #{inspect(role)}")
    end
  end

  defp lookup_role(nil), do: Error.wrap(:memory_error, "Message role is required")

  defp lookup_role(other),
    do: Error.wrap(:memory_error, "Invalid message role type: #{inspect(other)}")

  defp lookup_status(status) when is_binary(status) do
    case Map.fetch(@valid_statuses, status) do
      {:ok, atom} -> {:ok, atom}
      :error -> Error.wrap(:memory_error, "Unknown tool call status: #{inspect(status)}")
    end
  end

  defp lookup_status(nil), do: {:ok, :pending}

  defp lookup_status(other),
    do: Error.wrap(:memory_error, "Invalid tool call status type: #{inspect(other)}")

  defp deserialize_tool_calls(nil), do: {:ok, []}

  defp deserialize_tool_calls(list) when is_list(list) do
    deserialize_list(list, &deserialize_tool_call/1, [])
  end

  defp deserialize_tool_calls(other),
    do: Error.wrap(:memory_error, "Expected tool_calls to be an array, got: #{inspect(other)}")

  defp deserialize_tool_call(map) when is_map(map) do
    with {:ok, status} <- lookup_status(map["status"]),
         {:ok, id} <- validate_optional_string(map["id"], "tool_call.id"),
         {:ok, name} <- validate_optional_string(map["name"], "tool_call.name"),
         {:ok, arguments} <- validate_arguments(map["arguments"]) do
      tc = %ToolCall{
        id: id,
        name: name,
        arguments: arguments,
        status: status
      }

      {:ok, tc}
    end
  end

  defp deserialize_tool_call(other),
    do:
      Error.wrap(:memory_error, "Expected tool_call to be a JSON object, got: #{inspect(other)}")

  defp deserialize_tool_results(nil), do: {:ok, []}

  defp deserialize_tool_results(list) when is_list(list) do
    deserialize_list(list, &deserialize_tool_result/1, [])
  end

  defp deserialize_tool_results(other),
    do: Error.wrap(:memory_error, "Expected tool_results to be an array, got: #{inspect(other)}")

  defp deserialize_tool_result(map) when is_map(map) do
    with {:ok, tool_call_id} <-
           validate_optional_string(map["tool_call_id"], "tool_result.tool_call_id"),
         {:ok, name} <- validate_optional_string(map["name"], "tool_result.name"),
         {:ok, is_error} <- validate_boolean(map["is_error"], "tool_result.is_error") do
      tr = %ToolResult{
        tool_call_id: tool_call_id,
        name: name,
        content: map["content"],
        is_error: is_error
      }

      {:ok, tr}
    end
  end

  defp deserialize_tool_result(other),
    do:
      Error.wrap(
        :memory_error,
        "Expected tool_result to be a JSON object, got: #{inspect(other)}"
      )

  defp deserialize_list([], _fun, acc), do: {:ok, Enum.reverse(acc)}

  defp deserialize_list([item | rest], fun, acc) do
    case fun.(item) do
      {:ok, result} -> deserialize_list(rest, fun, [result | acc])
      {:error, _} = error -> error
    end
  end

  defp parse_datetime(nil), do: {:ok, nil}

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> Error.wrap(:memory_error, "Invalid datetime: #{inspect(reason)}")
    end
  end

  defp parse_datetime(other),
    do: Error.wrap(:memory_error, "Invalid datetime type: #{inspect(other)}")

  # --- Field type validators ---

  defp validate_metadata(nil), do: {:ok, %{}}
  defp validate_metadata(map) when is_map(map), do: {:ok, map}

  defp validate_metadata(other),
    do: Error.wrap(:memory_error, "Expected metadata to be a map, got: #{inspect(other)}")

  defp validate_optional_string(nil, _field), do: {:ok, nil}
  defp validate_optional_string(str, _field) when is_binary(str), do: {:ok, str}

  defp validate_optional_string(other, field),
    do: Error.wrap(:memory_error, "Expected #{field} to be a string, got: #{inspect(other)}")

  defp validate_arguments(nil), do: {:ok, %{}}
  defp validate_arguments(map) when is_map(map), do: {:ok, map}

  defp validate_arguments(other),
    do:
      Error.wrap(
        :memory_error,
        "Expected tool_call.arguments to be a map, got: #{inspect(other)}"
      )

  defp validate_boolean(nil, _field), do: {:ok, false}
  defp validate_boolean(val, _field) when is_boolean(val), do: {:ok, val}

  defp validate_boolean(other, field),
    do: Error.wrap(:memory_error, "Expected #{field} to be a boolean, got: #{inspect(other)}")
end
