defmodule Agora.Tool.ListDirectoryTest do
  use ExUnit.Case, async: true

  alias Agora.Tool.{ListDirectory, Sandbox}

  defp make_workspace do
    base =
      Path.join(
        System.tmp_dir!(),
        "list_dir_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
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

  describe "execute/2" do
    test "lists files in workspace" do
      ws = make_workspace()
      File.write!(Path.join(ws, "a.txt"), "aaa")
      File.write!(Path.join(ws, "b.txt"), "bbb")
      File.mkdir_p!(Path.join(ws, "subdir"))

      assert {:ok, entries} = ListDirectory.execute(%{"path" => "."}, context(ws))

      names = Enum.map(entries, & &1.name)
      assert "a.txt" in names
      assert "b.txt" in names
      assert "subdir" in names
    end

    test "returns type and size for entries" do
      ws = make_workspace()
      File.write!(Path.join(ws, "data.txt"), "12345")
      File.mkdir_p!(Path.join(ws, "dir"))

      assert {:ok, entries} = ListDirectory.execute(%{"path" => "."}, context(ws))

      file_entry = Enum.find(entries, &(&1.name == "data.txt"))
      assert file_entry.type == "regular"
      assert file_entry.size == 5

      dir_entry = Enum.find(entries, &(&1.name == "dir"))
      assert dir_entry.type == "directory"
    end

    test "filters by regex pattern" do
      ws = make_workspace()
      File.write!(Path.join(ws, "test.ex"), "")
      File.write!(Path.join(ws, "test.exs"), "")
      File.write!(Path.join(ws, "readme.md"), "")

      assert {:ok, entries} =
               ListDirectory.execute(
                 %{"path" => ".", "pattern" => "\\.exs?$"},
                 context(ws)
               )

      names = Enum.map(entries, & &1.name)
      assert "test.ex" in names
      assert "test.exs" in names
      refute "readme.md" in names
    end

    test "returns error for invalid pattern" do
      ws = make_workspace()

      assert {:error, msg} =
               ListDirectory.execute(
                 %{"path" => ".", "pattern" => "[invalid"},
                 context(ws)
               )

      assert msg =~ "Invalid filter pattern"
    end

    test "returns error for non-existent directory" do
      ws = make_workspace()

      assert {:error, msg} =
               ListDirectory.execute(%{"path" => "nope"}, context(ws))

      assert msg =~ "not found"
    end

    test "returns error when path is outside sandbox" do
      ws = make_workspace()

      assert {:error, msg} =
               ListDirectory.execute(%{"path" => "/etc"}, context(ws))

      assert msg =~ "outside allowed paths"
    end

    test "returns error when no sandbox configured" do
      assert {:error, msg} =
               ListDirectory.execute(%{"path" => "."}, %{})

      assert msg =~ "No sandbox configured"
    end

    test "defaults to working directory" do
      ws = make_workspace()
      File.write!(Path.join(ws, "file.txt"), "")

      assert {:ok, entries} = ListDirectory.execute(%{}, context(ws))
      names = Enum.map(entries, & &1.name)
      assert "file.txt" in names
    end
  end
end
