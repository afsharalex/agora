defmodule Agora.Tool.Shell do
  @moduledoc """
  Shell command execution tool with sandbox-enforced security.

  Executes system commands within the configured sandbox boundaries.
  Supports two modes:

    * `shell: false` (default) — uses `System.cmd/3` with an explicit argument list,
      preventing shell injection
    * `shell: true` — uses `System.shell/2` for shell features (pipes, redirects).
      Requires `allow_shell_mode: true` in the sandbox config.

  ## Timeout Precedence

  The tool declares a 60-second timeout via `timeout/0` (used by `ToolBroker` as the
  hard outer deadline). The sandbox's `shell_timeout` (default 30s) is the inner
  wall-clock limit on the command itself.

  ## Command Policy Caveats

  Command validation checks only the primary command (the first token in shell
  mode). This means:

    * **Interpreter bypass**: `sh -c "rm -rf /"` or `bash -c "..."` will pass
      validation if `sh`/`bash` are allowed but `rm` is denied. To prevent this,
      add interpreters (`sh`, `bash`, `zsh`, `python`, `perl`, `ruby`, `node`)
      to `denied_commands` when using a restrictive allowlist.
    * **Shell mode pipes**: `ls | rm` only validates `ls`. The allowlist applies
      only to the primary command.

  ## Environment Variables

  By default, commands inherit the process environment. Set `sandbox.env` to
  a list of `{key, value}` tuples to add or override specific variables.

  Note: Erlang's `env` option is additive — it merges with the process
  environment rather than replacing it. There is no way to run with a
  fully clean environment via `System.cmd/3`.

  ## Example

      sandbox = %Agora.Tool.Sandbox{
        working_directory: "/tmp/workspace",
        allowed_paths: ["/tmp/workspace"],
        allowed_commands: ["ls", "grep", "cat"],
        denied_commands: ["rm", "sudo"],
        allow_shell_mode: false
      }

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.Shell],
        tool_opts: [sandbox: sandbox]
      )

  """

  @behaviour Agora.Tool

  alias Agora.Tool.{Schema, Sandbox}

  @impl true
  def name, do: "shell"

  @impl true
  def description,
    do:
      "Execute a shell command. Commands run in the sandbox working directory. Requires sandbox."

  @impl true
  def schema do
    Schema.object(
      %{
        "command" => Schema.string(description: "The command to execute"),
        "args" =>
          Schema.array(Schema.string(), description: "Command arguments (for non-shell mode)"),
        "shell" =>
          Schema.boolean(
            description:
              "Use shell mode for pipes/redirects. Default: false. Requires allow_shell_mode in sandbox."
          )
      },
      required: ["command"]
    )
  end

  @impl true
  def timeout, do: 60_000

  @impl true
  def execute(%{"command" => command} = args, context) do
    shell_mode? = Map.get(args, "shell", false)
    cmd_args = Map.get(args, "args", [])

    case Map.get(context, :sandbox) do
      %Sandbox{} = sandbox ->
        with :ok <- validate_shell_mode(shell_mode?, sandbox),
             :ok <- Sandbox.validate_command(sandbox, extract_command(command, shell_mode?)) do
          run_command(command, cmd_args, shell_mode?, sandbox)
        end

      _ ->
        {:error, "No sandbox configured. Shell requires a sandbox in tool_opts."}
    end
  end

  defp validate_shell_mode(false, _sandbox), do: :ok
  defp validate_shell_mode(true, sandbox), do: Sandbox.validate_shell_mode(sandbox)

  defp extract_command(command, false), do: command

  defp extract_command(command, true) do
    # For shell mode, extract the first token as the primary command
    command |> String.split(~r/\s+/, parts: 2) |> List.first()
  end

  defp run_command(command, args, shell_mode?, sandbox) do
    task =
      Task.async(fn ->
        if shell_mode? do
          run_shell(command, sandbox)
        else
          run_cmd(command, args, sandbox)
        end
      end)

    case Task.yield(task, sandbox.shell_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, "Command timed out after #{sandbox.shell_timeout}ms"}

      {:exit, reason} ->
        {:error, "Command process exited: #{inspect(reason)}"}
    end
  end

  defp run_cmd(command, args, sandbox) do
    opts = build_cmd_opts(sandbox)

    try do
      {output, exit_code} = System.cmd(command, args, opts)
      format_result(output, exit_code, sandbox.max_output_size)
    rescue
      e in ErlangError ->
        {:error, "Command failed: #{Exception.message(e)}"}
    end
  end

  defp run_shell(command, sandbox) do
    opts = build_cmd_opts(sandbox)

    try do
      {output, exit_code} = System.shell(command, opts)
      format_result(output, exit_code, sandbox.max_output_size)
    rescue
      e in ErlangError ->
        {:error, "Shell command failed: #{Exception.message(e)}"}
    end
  end

  defp build_cmd_opts(sandbox) do
    opts = [cd: sandbox.working_directory, stderr_to_stdout: true]

    case sandbox.env do
      nil -> opts
      env -> Keyword.put(opts, :env, env)
    end
  end

  defp format_result(output, exit_code, max_output_size) do
    truncated = truncate_output(output, max_output_size)

    if exit_code == 0 do
      {:ok, %{exit_code: 0, output: truncated}}
    else
      {:error, "Command exited with code #{exit_code}: #{truncated}"}
    end
  end

  defp truncate_output(output, max_size) do
    if byte_size(output) > max_size do
      binary_part(output, 0, max_size) <> "\n... (output truncated at #{max_size} bytes)"
    else
      output
    end
  end
end
