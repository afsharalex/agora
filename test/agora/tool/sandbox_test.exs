defmodule Agora.Tool.SandboxTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.Sandbox

  defp make_workspace do
    base =
      Path.join(
        System.tmp_dir!(),
        "sandbox_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
      )

    File.mkdir_p!(base)
    # Return the real resolved path (handles macOS /tmp -> /private/tmp)
    base |> Path.expand() |> resolve_real()
  end

  # Walk every path component, resolving symlinks at each level.
  # This matches what Sandbox.resolve_real_path/1 does internally.
  defp resolve_real(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_components("/")
  end

  defp resolve_components([], acc), do: acc

  defp resolve_components([component | rest], acc) do
    candidate = Path.join(acc, component)

    case File.read_link(candidate) do
      {:ok, target} ->
        resolved = Path.expand(target, acc)
        resolve_components(rest, resolve_real(resolved))

      {:error, _} ->
        resolve_components(rest, candidate)
    end
  end

  defp sandbox(workspace, overrides \\ []) do
    defaults = %Sandbox{
      working_directory: workspace,
      allowed_paths: [workspace],
      denied_paths: [Path.join(workspace, "secrets")]
    }

    struct!(defaults, overrides)
  end

  describe "validate_path/2" do
    test "allows path within allowed prefix" do
      ws = make_workspace()

      assert {:ok, path} = Sandbox.validate_path(sandbox(ws), "notes.txt")
      assert path == Path.join(ws, "notes.txt")
    end

    test "allows absolute path within allowed prefix" do
      ws = make_workspace()
      abs_path = Path.join([ws, "subdir", "file.txt"])

      assert {:ok, ^abs_path} = Sandbox.validate_path(sandbox(ws), abs_path)
    end

    test "allows path to non-existent file within allowed prefix" do
      ws = make_workspace()

      assert {:ok, resolved} =
               Sandbox.validate_path(
                 sandbox(ws),
                 "new_file_#{System.unique_integer([:positive])}"
               )

      assert String.starts_with?(resolved, ws)
    end

    test "denies path outside allowed prefix" do
      ws = make_workspace()
      assert {:error, msg} = Sandbox.validate_path(sandbox(ws), "/etc/passwd")
      assert msg =~ "outside allowed paths"
    end

    test "denied paths win over allowed paths" do
      ws = make_workspace()
      File.mkdir_p!(Path.join(ws, "secrets"))
      assert {:error, msg} = Sandbox.validate_path(sandbox(ws), "secrets/key.pem")
      assert msg =~ "denied paths"
    end

    test "resolves relative paths against working_directory" do
      ws = make_workspace()

      assert {:ok, resolved} = Sandbox.validate_path(sandbox(ws), "subdir/file.txt")
      assert resolved == Path.join([ws, "subdir", "file.txt"])
    end

    test "resolves parent directory traversal" do
      ws = make_workspace()
      assert {:error, _} = Sandbox.validate_path(sandbox(ws), "../../../etc/passwd")
    end

    test "follows symlinks and rejects if target is outside allowed paths" do
      ws = make_workspace()

      outside =
        Path.join(
          Path.dirname(ws),
          "outside_#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
        )

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret data")

      # Create a symlink inside workspace pointing outside
      link_path = Path.join(ws, "escape_link")
      File.ln_s!(Path.join(outside, "secret.txt"), link_path)

      sb = sandbox(ws, denied_paths: [])

      # The symlink resolves to outside, which is not under allowed_paths
      assert {:error, msg} = Sandbox.validate_path(sb, "escape_link")
      assert msg =~ "outside allowed paths"

      File.rm_rf!(outside)
      File.rm_rf!(ws)
    end

    test "follows symlinks and allows if target is within allowed paths" do
      ws = make_workspace()
      subdir = Path.join(ws, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "data.txt"), "ok")

      link_path = Path.join(ws, "data_link")
      File.ln_s!(Path.join(subdir, "data.txt"), link_path)

      sb = sandbox(ws, denied_paths: [])

      assert {:ok, resolved} = Sandbox.validate_path(sb, "data_link")
      assert String.starts_with?(resolved, ws)

      File.rm_rf!(ws)
    end

    test "empty allowed_paths denies everything" do
      ws = make_workspace()
      sb = sandbox(ws, allowed_paths: [])
      assert {:error, _} = Sandbox.validate_path(sb, "anything.txt")
      File.rm_rf!(ws)
    end

    test "prefix boundary: /workspace does not allow /workspace_evil" do
      ws = make_workspace()
      evil_dir = ws <> "_evil"
      File.mkdir_p!(evil_dir)
      File.write!(Path.join(evil_dir, "payload.txt"), "bad")
      on_exit(fn -> File.rm_rf!(evil_dir) end)

      sb = sandbox(ws, denied_paths: [])

      assert {:error, msg} = Sandbox.validate_path(sb, Path.join(evil_dir, "payload.txt"))
      assert msg =~ "outside allowed paths"
    end

    test "prefix boundary: denied /workspace/secret does not deny /workspace/secretfiles" do
      ws = make_workspace()
      File.mkdir_p!(Path.join(ws, "secretfiles"))
      File.write!(Path.join(ws, "secretfiles/ok.txt"), "fine")

      # denied_paths has "secrets" (from default sandbox), not "secretfiles"
      sb = sandbox(ws)

      assert {:ok, _} = Sandbox.validate_path(sb, "secretfiles/ok.txt")
    end

    test "exact match on allowed path is accepted" do
      ws = make_workspace()
      sb = sandbox(ws, denied_paths: [])

      # Validate the workspace directory itself
      assert {:ok, resolved} = Sandbox.validate_path(sb, ws)
      assert resolved == ws
    end

    test "rejects symlinked directory component that escapes sandbox" do
      ws = make_workspace()

      outside =
        Path.join(
          Path.dirname(ws),
          "outside_dir_#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
        )

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "target.txt"), "escaped")

      # Create a symlinked directory inside workspace that points outside
      link_dir = Path.join(ws, "linked_dir")
      File.ln_s!(outside, link_dir)

      sb = sandbox(ws, denied_paths: [])

      # Accessing a file through the symlinked directory should be rejected
      assert {:error, msg} = Sandbox.validate_path(sb, "linked_dir/target.txt")
      assert msg =~ "outside allowed paths"

      File.rm_rf!(outside)
    end
  end

  describe "validate_command/2" do
    test "allows command when allowed_commands is :all" do
      ws = make_workspace()
      sb = sandbox(ws, allowed_commands: :all, denied_commands: [])
      assert :ok = Sandbox.validate_command(sb, "ls")
    end

    test "allows command in allowed list" do
      ws = make_workspace()
      sb = sandbox(ws, allowed_commands: ["ls", "grep"], denied_commands: [])
      assert :ok = Sandbox.validate_command(sb, "ls")
    end

    test "denies command not in allowed list" do
      ws = make_workspace()
      sb = sandbox(ws, allowed_commands: ["ls", "grep"], denied_commands: [])
      assert {:error, msg} = Sandbox.validate_command(sb, "rm")
      assert msg =~ "not in the allowed commands list"
    end

    test "denied commands win over allowed commands" do
      ws = make_workspace()
      sb = sandbox(ws, allowed_commands: :all, denied_commands: ["rm", "sudo"])
      assert {:error, msg} = Sandbox.validate_command(sb, "rm")
      assert msg =~ "denied"
    end

    test "normalizes full path to basename" do
      ws = make_workspace()
      sb = sandbox(ws, allowed_commands: ["ls"], denied_commands: [])
      assert :ok = Sandbox.validate_command(sb, "/usr/bin/ls")
    end

    test "normalizes full path for denied check" do
      ws = make_workspace()
      sb = sandbox(ws, allowed_commands: :all, denied_commands: ["rm"])
      assert {:error, _} = Sandbox.validate_command(sb, "/usr/bin/rm")
    end
  end

  describe "validate_shell_mode/1" do
    test "allows when allow_shell_mode is true" do
      ws = make_workspace()
      sb = sandbox(ws, allow_shell_mode: true)
      assert :ok = Sandbox.validate_shell_mode(sb)
    end

    test "denies when allow_shell_mode is false" do
      ws = make_workspace()
      sb = sandbox(ws, allow_shell_mode: false)
      assert {:error, msg} = Sandbox.validate_shell_mode(sb)
      assert msg =~ "Shell mode is disabled"
    end
  end
end
