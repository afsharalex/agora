defmodule Agora.Tool.ReadFileTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.{ReadFile, Sandbox}

  defp make_workspace do
    base =
      Path.join(
        System.tmp_dir!(),
        "read_file_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
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
      max_file_size: 10_485_760
    }

    struct!(defaults, overrides)
  end

  defp context(ws, overrides \\ []) do
    %{sandbox: sandbox(ws, overrides)}
  end

  describe "execute/2" do
    test "reads a utf8 file" do
      ws = make_workspace()
      File.write!(Path.join(ws, "hello.txt"), "Hello, world!")

      assert {:ok, "Hello, world!"} =
               ReadFile.execute(%{"path" => "hello.txt"}, context(ws))
    end

    test "reads a binary file as base64" do
      ws = make_workspace()
      binary = <<0, 1, 2, 3, 255>>
      File.write!(Path.join(ws, "data.bin"), binary)

      assert {:ok, encoded} =
               ReadFile.execute(
                 %{"path" => "data.bin", "encoding" => "binary"},
                 context(ws)
               )

      assert Base.decode64!(encoded) == binary
    end

    test "returns error for non-existent file" do
      ws = make_workspace()

      assert {:error, msg} =
               ReadFile.execute(%{"path" => "nope.txt"}, context(ws))

      assert msg =~ "not found"
    end

    test "returns error when file exceeds max_file_size" do
      ws = make_workspace()
      File.write!(Path.join(ws, "big.txt"), String.duplicate("x", 100))

      assert {:error, msg} =
               ReadFile.execute(
                 %{"path" => "big.txt"},
                 %{sandbox: sandbox(ws, max_file_size: 50)}
               )

      assert msg =~ "exceeds maximum"
    end

    test "returns error when path is outside sandbox" do
      ws = make_workspace()

      assert {:error, msg} =
               ReadFile.execute(%{"path" => "/etc/passwd"}, context(ws))

      assert msg =~ "outside allowed paths"
    end

    test "returns error when no sandbox configured" do
      assert {:error, msg} =
               ReadFile.execute(%{"path" => "file.txt"}, %{})

      assert msg =~ "No sandbox configured"
    end

    test "rejects symlink traversal" do
      ws = make_workspace()

      outside =
        Path.join(
          Path.dirname(ws),
          "outside_rf_#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
        )

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret")
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(ws, "link"))
      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:error, msg} =
               ReadFile.execute(%{"path" => "link"}, context(ws))

      assert msg =~ "outside allowed paths"
    end
  end
end
