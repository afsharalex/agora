defmodule Agora.Tool.WriteFile do
  @moduledoc """
  File writing tool with sandbox-enforced path validation.

  Writes or appends content to files within the configured sandbox boundaries.
  Creates parent directories if they don't exist and are within allowed paths.
  Requires a `%Agora.Tool.Sandbox{}` in the tool execution context.

  ## Write Modes

    * `write` (default) — atomic write via temp file + rename
    * `append` — appends to existing file (inherently non-atomic)

  ## Example

      sandbox = %Agora.Tool.Sandbox{
        working_directory: "/tmp/workspace",
        allowed_paths: ["/tmp/workspace"]
      }

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.WriteFile],
        tool_opts: [sandbox: sandbox]
      )

  """

  @behaviour Agora.Tool

  alias Agora.Tool.{Schema, Sandbox}

  @impl true
  def name, do: "write_file"

  @impl true
  def description,
    do:
      "Write or append content to a file. Paths are relative to the working directory. Requires sandbox."

  @impl true
  def schema do
    Schema.object(
      %{
        "path" =>
          Schema.string(
            description: "Path to the file (absolute or relative to working directory)"
          ),
        "content" => Schema.string(description: "Content to write"),
        "mode" =>
          Schema.enum(["write", "append"],
            description: "Write mode. 'write' is atomic (default), 'append' adds to end of file."
          )
      },
      required: ["path", "content"]
    )
  end

  @impl true
  def execute(%{"path" => path, "content" => content} = args, context) do
    mode = Map.get(args, "mode", "write")

    case Map.get(context, :sandbox) do
      %Sandbox{} = sandbox ->
        with {:ok, resolved} <- Sandbox.validate_path(sandbox, path),
             :ok <- ensure_parent_dir(resolved) do
          do_write(resolved, content, mode)
        end

      _ ->
        {:error, "No sandbox configured. WriteFile requires a sandbox in tool_opts."}
    end
  end

  defp ensure_parent_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create directory #{dir}: #{reason}"}
    end
  end

  defp do_write(path, content, "write") do
    # Atomic write: write to temp file, then rename
    tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      {:ok, %{path: path, bytes_written: byte_size(content)}}
    else
      {:error, reason} ->
        # Clean up temp file on failure
        File.rm(tmp_path)
        {:error, "Failed to write file: #{reason}"}
    end
  end

  defp do_write(path, content, "append") do
    case File.write(path, content, [:append]) do
      :ok -> {:ok, %{path: path, bytes_written: byte_size(content)}}
      {:error, reason} -> {:error, "Failed to append to file: #{reason}"}
    end
  end
end
