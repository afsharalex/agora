defmodule Agora.Tool.ReadFile do
  @moduledoc """
  File reading tool with sandbox-enforced path validation.

  Reads files within the configured sandbox boundaries. Supports UTF-8 text
  and binary (Base64-encoded) modes. Requires a `%Agora.Tool.Sandbox{}` in
  the tool execution context.

  ## Example

      sandbox = %Agora.Tool.Sandbox{
        working_directory: "/tmp/workspace",
        allowed_paths: ["/tmp/workspace"],
        max_file_size: 10_485_760
      }

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.ReadFile],
        tool_opts: [sandbox: sandbox]
      )

  """

  @behaviour Agora.Tool

  alias Agora.Tool.{Schema, Sandbox}

  @impl true
  def name, do: "read_file"

  @impl true
  def description,
    do: "Read a file's contents. Paths are relative to the working directory. Requires sandbox."

  @impl true
  def schema do
    Schema.object(
      %{
        "path" =>
          Schema.string(
            description: "Path to the file (absolute or relative to working directory)"
          ),
        "encoding" =>
          Schema.enum(["utf8", "binary"],
            description: "File encoding. 'binary' returns Base64-encoded content. Default: utf8"
          )
      },
      required: ["path"]
    )
  end

  @impl true
  def execute(%{"path" => path} = args, context) do
    encoding = Map.get(args, "encoding", "utf8")

    case Map.get(context, :sandbox) do
      %Sandbox{} = sandbox ->
        with {:ok, resolved} <- Sandbox.validate_path(sandbox, path),
             :ok <- check_file_size(resolved, sandbox.max_file_size) do
          read_file(resolved, encoding)
        end

      _ ->
        {:error, "No sandbox configured. ReadFile requires a sandbox in tool_opts."}
    end
  end

  defp check_file_size(path, max_size) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > max_size ->
        {:error, "File size #{size} bytes exceeds maximum #{max_size} bytes"}

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, reason} ->
        {:error, "Cannot stat file: #{reason}"}
    end
  end

  defp read_file(path, "utf8") do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end

  defp read_file(path, "binary") do
    case File.read(path) do
      {:ok, content} -> {:ok, Base.encode64(content)}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end
end
