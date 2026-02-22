defmodule Agora.Tool.WriteFileTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.{WriteFile, Sandbox}

  defp make_workspace do
    base =
      Path.join(
        System.tmp_dir!(),
        "write_file_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
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

  defp sandbox(ws) do
    %Sandbox{
      working_directory: ws,
      allowed_paths: [ws],
      denied_paths: []
    }
  end

  defp context(ws), do: %{sandbox: sandbox(ws)}

  describe "execute/2 - write mode" do
    test "writes a new file" do
      ws = make_workspace()

      assert {:ok, %{path: path, bytes_written: 13}} =
               WriteFile.execute(
                 %{"path" => "test.txt", "content" => "Hello, world!"},
                 context(ws)
               )

      assert File.read!(path) == "Hello, world!"
    end

    test "overwrites existing file atomically" do
      ws = make_workspace()
      File.write!(Path.join(ws, "existing.txt"), "old content")

      assert {:ok, %{path: path}} =
               WriteFile.execute(
                 %{"path" => "existing.txt", "content" => "new content"},
                 context(ws)
               )

      assert File.read!(path) == "new content"
    end

    test "creates parent directories" do
      ws = make_workspace()

      assert {:ok, %{path: path}} =
               WriteFile.execute(
                 %{"path" => "subdir/deep/file.txt", "content" => "deep content"},
                 context(ws)
               )

      assert File.read!(path) == "deep content"
    end

    test "writes to non-existent path under allowed prefix" do
      ws = make_workspace()

      assert {:ok, _} =
               WriteFile.execute(
                 %{"path" => "brand_new_file.txt", "content" => "hello"},
                 context(ws)
               )
    end
  end

  describe "execute/2 - append mode" do
    test "appends to existing file" do
      ws = make_workspace()
      File.write!(Path.join(ws, "log.txt"), "line 1\n")

      assert {:ok, %{bytes_written: 7}} =
               WriteFile.execute(
                 %{"path" => "log.txt", "content" => "line 2\n", "mode" => "append"},
                 context(ws)
               )

      assert File.read!(Path.join(ws, "log.txt")) == "line 1\nline 2\n"
    end

    test "creates file if it doesn't exist in append mode" do
      ws = make_workspace()

      assert {:ok, _} =
               WriteFile.execute(
                 %{"path" => "new_log.txt", "content" => "first line\n", "mode" => "append"},
                 context(ws)
               )

      assert File.read!(Path.join(ws, "new_log.txt")) == "first line\n"
    end
  end

  describe "execute/2 - security" do
    test "returns error when path is outside sandbox" do
      ws = make_workspace()

      assert {:error, msg} =
               WriteFile.execute(
                 %{"path" => "/etc/evil.txt", "content" => "hack"},
                 context(ws)
               )

      assert msg =~ "outside allowed paths"
    end

    test "returns error when no sandbox configured" do
      assert {:error, msg} =
               WriteFile.execute(
                 %{"path" => "file.txt", "content" => "data"},
                 %{}
               )

      assert msg =~ "No sandbox configured"
    end
  end
end
