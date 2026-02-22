defmodule Agora.Tool.ListDirectory do
  @moduledoc """
  Directory listing tool with sandbox-enforced path validation.

  Lists files and directories within the configured sandbox boundaries.
  Supports regex-based filename filtering and returns file metadata
  (name, type, size). Capped at 1000 entries. Requires a
  `%Agora.Tool.Sandbox{}` in the tool execution context.

  ## Example

      sandbox = %Agora.Tool.Sandbox{
        working_directory: "/tmp/workspace",
        allowed_paths: ["/tmp/workspace"]
      }

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.ListDirectory],
        tool_opts: [sandbox: sandbox]
      )

  """

  @behaviour Agora.Tool

  alias Agora.Tool.{Schema, Sandbox}

  @max_entries 1000

  @impl true
  def name, do: "list_directory"

  @impl true
  def description,
    do:
      "List files and directories. Paths are relative to the working directory. Requires sandbox."

  @impl true
  def schema do
    Schema.object(
      %{
        "path" =>
          Schema.string(
            description:
              "Directory path (absolute or relative to working directory). Default: working directory"
          ),
        "pattern" =>
          Schema.string(
            description:
              "Regex pattern to filter filenames (applied to names only, not full paths)"
          )
      },
      required: []
    )
  end

  @impl true
  def execute(args, context) do
    path = Map.get(args, "path", ".")
    pattern = Map.get(args, "pattern")

    case Map.get(context, :sandbox) do
      %Sandbox{} = sandbox ->
        with {:ok, resolved} <- Sandbox.validate_path(sandbox, path),
             {:ok, entries} <- list_dir(resolved),
             {:ok, regex} <- compile_pattern(pattern) do
          results =
            entries
            |> maybe_filter(regex)
            |> Enum.take(@max_entries)
            |> Enum.map(fn name -> stat_entry(resolved, name) end)

          {:ok, results}
        end

      _ ->
        {:error, "No sandbox configured. ListDirectory requires a sandbox in tool_opts."}
    end
  end

  defp list_dir(path) do
    case File.ls(path) do
      {:ok, entries} -> {:ok, Enum.sort(entries)}
      {:error, :enoent} -> {:error, "Directory not found: #{path}"}
      {:error, :enotdir} -> {:error, "Not a directory: #{path}"}
      {:error, reason} -> {:error, "Failed to list directory: #{reason}"}
    end
  end

  defp compile_pattern(nil), do: {:ok, nil}

  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "Invalid filter pattern: #{reason}"}
    end
  end

  defp maybe_filter(entries, nil), do: entries

  defp maybe_filter(entries, regex) do
    Enum.filter(entries, fn name -> Regex.match?(regex, name) end)
  end

  defp stat_entry(dir, name) do
    path = Path.join(dir, name)

    case File.stat(path) do
      {:ok, %File.Stat{type: type, size: size}} ->
        %{name: name, type: to_string(type), size: size}

      {:error, _} ->
        %{name: name, type: "unknown", size: 0}
    end
  end
end
