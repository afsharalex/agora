defmodule Agora.Tool.ShellTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.{Shell, Sandbox}

  defp make_workspace do
    base =
      Path.join(
        System.tmp_dir!(),
        "shell_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
      )

    File.mkdir_p!(base)
    real_base = resolve_real(base)
    on_exit(fn -> File.rm_rf!(base) end)
    real_base
  end

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

  defp sandbox(ws, overrides \\ []) do
    defaults = %Sandbox{
      working_directory: ws,
      allowed_paths: [ws],
      denied_paths: [],
      allowed_commands: :all,
      denied_commands: [],
      shell_timeout: 5_000,
      max_output_size: 1_048_576,
      allow_shell_mode: false
    }

    struct!(defaults, overrides)
  end

  defp context(ws, overrides \\ []) do
    %{sandbox: sandbox(ws, overrides)}
  end

  describe "execute/2 - basic command execution" do
    test "runs a simple command" do
      ws = make_workspace()

      assert {:ok, %{exit_code: 0, output: output}} =
               Shell.execute(%{"command" => "echo", "args" => ["hello"]}, context(ws))

      assert String.trim(output) == "hello"
    end

    test "runs command in working directory" do
      ws = make_workspace()
      File.write!(Path.join(ws, "test_marker.txt"), "")

      assert {:ok, %{exit_code: 0, output: output}} =
               Shell.execute(%{"command" => "ls"}, context(ws))

      assert output =~ "test_marker.txt"
    end

    test "returns error for non-zero exit code" do
      ws = make_workspace()

      assert {:error, msg} =
               Shell.execute(
                 %{"command" => "ls", "args" => ["nonexistent_dir_#{System.unique_integer()}"]},
                 context(ws)
               )

      assert msg =~ "exited with code"
    end
  end

  describe "execute/2 - shell mode" do
    test "shell mode denied when allow_shell_mode is false" do
      ws = make_workspace()

      assert {:error, msg} =
               Shell.execute(
                 %{"command" => "echo hello | cat", "shell" => true},
                 context(ws, allow_shell_mode: false)
               )

      assert msg =~ "Shell mode is disabled"
    end

    test "shell mode works when allow_shell_mode is true" do
      ws = make_workspace()

      assert {:ok, %{exit_code: 0, output: output}} =
               Shell.execute(
                 %{"command" => "echo hello", "shell" => true},
                 context(ws, allow_shell_mode: true)
               )

      assert String.trim(output) == "hello"
    end
  end

  describe "execute/2 - command validation" do
    test "denied commands are blocked" do
      ws = make_workspace()

      assert {:error, msg} =
               Shell.execute(
                 %{"command" => "rm", "args" => ["-rf", "/"]},
                 context(ws, denied_commands: ["rm", "sudo"])
               )

      assert msg =~ "denied"
    end

    test "allowed commands list restricts execution" do
      ws = make_workspace()

      assert {:error, msg} =
               Shell.execute(
                 %{"command" => "cat"},
                 context(ws, allowed_commands: ["ls", "echo"])
               )

      assert msg =~ "not in the allowed commands list"
    end
  end

  describe "execute/2 - timeout" do
    test "times out on long-running command" do
      ws = make_workspace()

      assert {:error, msg} =
               Shell.execute(
                 %{"command" => "sleep", "args" => ["10"]},
                 context(ws, shell_timeout: 100)
               )

      assert msg =~ "timed out"
    end
  end

  describe "execute/2 - output truncation" do
    test "truncates output exceeding max_output_size" do
      ws = make_workspace()
      # Generate output larger than 50 bytes
      large_content = String.duplicate("x", 100)
      File.write!(Path.join(ws, "big.txt"), large_content)

      assert {:ok, %{output: output}} =
               Shell.execute(
                 %{"command" => "cat", "args" => ["big.txt"]},
                 context(ws, max_output_size: 50)
               )

      assert output =~ "truncated"
      assert byte_size(output) < 200
    end
  end

  describe "execute/2 - environment" do
    test "inherits process env by default" do
      ws = make_workspace()

      assert {:ok, %{exit_code: 0, output: output}} =
               Shell.execute(
                 %{"command" => "env"},
                 context(ws)
               )

      # Should have at least some env vars
      assert String.length(output) > 0
    end

    test "uses explicit env when set" do
      ws = make_workspace()

      assert {:ok, %{exit_code: 0, output: output}} =
               Shell.execute(
                 %{"command" => "env"},
                 context(ws, env: [{"MY_VAR", "my_value"}])
               )

      assert output =~ "MY_VAR=my_value"
    end

    test "custom env does not include custom var when not set" do
      ws = make_workspace()
      unique_var = "AGORA_TEST_#{System.unique_integer([:positive])}"

      # The var should not appear since we only set env to empty (additive to OS env)
      assert {:ok, %{exit_code: 0, output: output}} =
               Shell.execute(
                 %{"command" => "env"},
                 context(ws, env: [])
               )

      refute output =~ "#{unique_var}="
    end
  end

  describe "execute/2 - security" do
    test "returns error when no sandbox configured" do
      assert {:error, msg} =
               Shell.execute(%{"command" => "ls"}, %{})

      assert msg =~ "No sandbox configured"
    end
  end

  describe "timeout/0" do
    test "returns 60_000" do
      assert Shell.timeout() == 60_000
    end
  end
end
