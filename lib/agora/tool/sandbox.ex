defmodule Agora.Tool.Sandbox do
  @moduledoc """
  Security configuration for system-interactive tools (file I/O, shell execution).

  Tools that access the filesystem or execute commands require a Sandbox to
  define security boundaries. The sandbox uses prefix-based path matching
  (not globs) so it works for both existing and non-existent paths.

  ## Path Validation

  `validate_path/2` resolves relative paths against `working_directory`,
  follows symlinks to their real targets, and checks the resolved path
  against `allowed_paths` and `denied_paths` prefix lists. Denied paths
  always win over allowed paths.

  ## Command Validation

  `validate_command/2` normalizes commands to their basename (e.g.,
  `/usr/bin/ls` becomes `ls`) and checks against `allowed_commands` and
  `denied_commands`. Denied commands always win.

  ## Example

      sandbox = %Agora.Tool.Sandbox{
        working_directory: "/tmp/workspace",
        allowed_paths: ["/tmp/workspace"],
        denied_paths: ["/tmp/workspace/secrets"],
        allowed_commands: ["ls", "grep", "cat"],
        denied_commands: ["rm", "sudo"]
      }

      {:ok, path} = Agora.Tool.Sandbox.validate_path(sandbox, "notes.txt")
      # => {:ok, "/tmp/workspace/notes.txt"}

      :ok = Agora.Tool.Sandbox.validate_command(sandbox, "ls")
      # => :ok

  """

  @type t :: %__MODULE__{
          working_directory: String.t(),
          allowed_paths: [String.t()],
          denied_paths: [String.t()],
          allowed_commands: :all | [String.t()],
          denied_commands: [String.t()],
          max_file_size: pos_integer(),
          max_output_size: pos_integer(),
          shell_timeout: pos_integer(),
          allow_shell_mode: boolean(),
          env: [{String.t(), String.t() | nil}] | nil
        }

  defstruct working_directory: "/tmp",
            allowed_paths: [],
            denied_paths: [],
            allowed_commands: :all,
            denied_commands: [],
            max_file_size: 10_485_760,
            max_output_size: 1_048_576,
            shell_timeout: 30_000,
            allow_shell_mode: false,
            env: nil

  @doc """
  Validates that a path is within the sandbox's allowed boundaries.

  1. Resolves relative paths against `working_directory`
  2. Resolves symlinks to real paths (for existing paths; for new files, resolves the parent)
  3. Checks against `denied_paths` (deny wins)
  4. Checks against `allowed_paths`

  Returns `{:ok, resolved_path}` or `{:error, reason}`.
  """
  @spec validate_path(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_path(%__MODULE__{} = sandbox, path) do
    expanded = Path.expand(path, sandbox.working_directory)
    resolved = resolve_real_path(expanded)

    # Canonicalize prefixes through the same symlink resolution so that
    # e.g. /tmp/workspace and /private/tmp/workspace compare correctly
    # on macOS where /tmp is a symlink to /private/tmp.
    canonical_allowed = Enum.map(sandbox.allowed_paths, &resolve_real_path/1)
    canonical_denied = Enum.map(sandbox.denied_paths, &resolve_real_path/1)

    cond do
      denied_path?(resolved, canonical_denied) ->
        {:error, "Path #{path} resolves to #{resolved} which is in denied paths"}

      allowed_path?(resolved, canonical_allowed) ->
        {:ok, resolved}

      true ->
        {:error, "Path #{path} resolves to #{resolved} which is outside allowed paths"}
    end
  end

  @doc """
  Validates that a command is allowed by the sandbox.

  Extracts the basename from the command (handles both `"ls"` and `"/usr/bin/ls"`),
  then checks against `denied_commands` (deny wins) and `allowed_commands`.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_command(t(), String.t()) :: :ok | {:error, String.t()}
  def validate_command(%__MODULE__{} = sandbox, command) do
    basename = Path.basename(command)

    cond do
      basename in sandbox.denied_commands ->
        {:error, "Command '#{basename}' is denied"}

      sandbox.allowed_commands == :all ->
        :ok

      basename in sandbox.allowed_commands ->
        :ok

      true ->
        {:error, "Command '#{basename}' is not in the allowed commands list"}
    end
  end

  @doc """
  Validates that shell mode is allowed by the sandbox.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_shell_mode(t()) :: :ok | {:error, String.t()}
  def validate_shell_mode(%__MODULE__{allow_shell_mode: true}), do: :ok

  def validate_shell_mode(%__MODULE__{allow_shell_mode: false}) do
    {:error, "Shell mode is disabled. Set allow_shell_mode: true in sandbox to enable"}
  end

  # Resolves symlinks at every directory component of the path to get the real
  # filesystem path. This catches symlinked parent directories that would escape
  # the sandbox (e.g., /workspace/link_to_etc/passwd where link_to_etc -> /etc).
  #
  # For non-existent paths, resolves as far as possible and appends remaining
  # components literally.
  defp resolve_real_path(path) do
    components = Path.split(path)
    resolve_components(components, "/")
  end

  defp resolve_components([], acc), do: acc

  defp resolve_components([component | rest], acc) do
    candidate = Path.join(acc, component)

    case File.read_link(candidate) do
      {:ok, target} ->
        # Symlink — resolve the target (may be relative to the link's parent)
        resolved = Path.expand(target, acc)
        # The resolved target itself could have more symlinks, so re-resolve it fully
        fully_resolved = resolve_real_path(resolved)
        resolve_components(rest, fully_resolved)

      {:error, :einval} ->
        # Not a symlink — regular file/dir, continue walking
        resolve_components(rest, candidate)

      {:error, :enoent} ->
        # Path doesn't exist from here on — append remaining components literally
        Enum.reduce(rest, candidate, fn c, a -> Path.join(a, c) end)
    end
  end

  # Checks whether `resolved` falls under any prefix in the list.
  # Uses directory-boundary-aware matching: the prefix must be an exact match
  # or the resolved path must be under the prefix as a directory (i.e., the next
  # character after the prefix is "/"). This prevents /tmp/workspace from
  # matching /tmp/workspace_evil.
  defp denied_path?(resolved, denied_paths) do
    Enum.any?(denied_paths, fn denied ->
      path_under_prefix?(resolved, denied)
    end)
  end

  defp allowed_path?(resolved, allowed_paths) do
    Enum.any?(allowed_paths, fn allowed ->
      path_under_prefix?(resolved, allowed)
    end)
  end

  defp path_under_prefix?(path, prefix) do
    path == prefix or String.starts_with?(path, ensure_trailing_slash(prefix))
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end
end
