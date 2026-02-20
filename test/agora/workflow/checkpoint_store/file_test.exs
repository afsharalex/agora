defmodule Agora.Workflow.CheckpointStore.FileTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.CheckpointStore.File, as: FileBackend

  defp unique_path do
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "agora_checkpoint_test_#{suffix}.json")
  end

  setup do
    path = unique_path()
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  describe "init/1" do
    test "initializes with valid path", %{path: path} do
      assert {:ok, state} = FileBackend.init(path: path)
      assert state.path == path
    end

    test "initializes when file already exists with valid JSON", %{path: path} do
      File.write!(path, "{}")
      assert {:ok, _state} = FileBackend.init(path: path)
    end

    test "returns error for non-JSON file", %{path: path} do
      File.write!(path, "not json")
      assert {:error, error} = FileBackend.init(path: path)
      assert error.type == :workflow_error
      assert error.message =~ "JSON decode"
    end

    test "returns error for non-object JSON", %{path: path} do
      File.write!(path, "[1, 2, 3]")
      assert {:error, error} = FileBackend.init(path: path)
      assert error.type == :workflow_error
      assert error.message =~ "Expected JSON object"
    end

    test "returns error when path is missing" do
      assert {:error, error} = FileBackend.init([])
      assert error.type == :workflow_error
      assert error.message =~ ":path is required"
    end

    test "returns error when path is not a string" do
      assert {:error, error} = FileBackend.init(path: 123)
      assert error.type == :workflow_error
      assert error.message =~ ":path must be a string"
    end
  end

  describe "save/3 and load/2" do
    test "round-trip save and load with result tuples", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, :step_a, {:ok, 42})
      assert {:ok, {:ok, 42}} = FileBackend.load(state, :step_a)
    end

    test "round-trip with error result", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      error = Agora.Error.new(:workflow_error, "failed")
      {:ok, state} = FileBackend.save(state, :step_a, {:error, error})
      assert {:ok, {:error, %Agora.Error{}}} = FileBackend.load(state, :step_a)
    end

    test "round-trip with skipped result", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, :step_a, :skipped)
      assert {:ok, :skipped} = FileBackend.load(state, :step_a)
    end

    test "persists to disk", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      {:ok, _state} = FileBackend.save(state, :my_step, {:ok, "hello"})

      content = File.read!(path)
      assert content =~ "my_step"
    end

    test "overwrites previous value", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, :step_a, {:ok, "first"})
      {:ok, state} = FileBackend.save(state, :step_a, {:ok, "second"})
      assert {:ok, {:ok, "second"}} = FileBackend.load(state, :step_a)
    end
  end

  describe "load/2" do
    test "returns nil for missing step", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      assert {:ok, nil} = FileBackend.load(state, :nonexistent)
    end
  end

  describe "load_all/1" do
    test "returns all saved results as string-keyed map", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, :a, {:ok, 1})
      {:ok, state} = FileBackend.save(state, :b, {:ok, 2})

      assert {:ok, results} = FileBackend.load_all(state)
      assert results["a"] == {:ok, 1}
      assert results["b"] == {:ok, 2}
    end

    test "returns empty map when nothing saved", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      assert {:ok, %{}} = FileBackend.load_all(state)
    end
  end

  describe "clear/1" do
    test "removes checkpoint file", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      {:ok, state} = FileBackend.save(state, :a, 1)
      assert File.exists?(path)

      {:ok, _state} = FileBackend.clear(state)
      refute File.exists?(path)
    end

    test "succeeds when file does not exist", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      assert {:ok, _state} = FileBackend.clear(state)
    end
  end

  describe "namespace" do
    test "prefixes keys with namespace", %{path: path} do
      {:ok, state} = FileBackend.init(path: path, namespace: "wf1")
      {:ok, _state} = FileBackend.save(state, :step_a, "value")

      content = File.read!(path) |> Jason.decode!()
      assert Map.has_key?(content, "wf1:step_a")
    end

    test "load_all strips namespace prefix", %{path: path} do
      {:ok, state} = FileBackend.init(path: path, namespace: "wf1")
      {:ok, state} = FileBackend.save(state, :a, {:ok, 1})
      {:ok, state} = FileBackend.save(state, :b, {:ok, 2})

      assert {:ok, results} = FileBackend.load_all(state)
      assert results["a"] == {:ok, 1}
      assert results["b"] == {:ok, 2}
    end

    test "load_all only returns namespaced keys", %{path: path} do
      # Write some non-namespaced data first
      File.write!(
        path,
        Jason.encode!(%{
          "other:x" => %{"_status" => "ok", "value" => 99},
          "wf1:a" => %{"_status" => "ok", "value" => 1}
        })
      )

      {:ok, state} = FileBackend.init(path: path, namespace: "wf1")
      assert {:ok, results} = FileBackend.load_all(state)
      assert results == %{"a" => {:ok, 1}}
    end

    test "clear only removes namespaced entries, preserves others", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "other:x" => %{"_status" => "ok", "value" => 99},
          "wf1:a" => %{"_status" => "ok", "value" => 1},
          "wf1:b" => %{"_status" => "ok", "value" => 2}
        })
      )

      {:ok, state} = FileBackend.init(path: path, namespace: "wf1")
      {:ok, _state} = FileBackend.clear(state)

      # File still exists with the non-namespaced data
      assert File.exists?(path)
      content = File.read!(path) |> Jason.decode!()
      assert Map.has_key?(content, "other:x")
      refute Map.has_key?(content, "wf1:a")
      refute Map.has_key?(content, "wf1:b")
    end

    test "clear does not create file when none exists", %{path: path} do
      refute File.exists?(path)

      {:ok, state} = FileBackend.init(path: path, namespace: "wf1")
      {:ok, _state} = FileBackend.clear(state)

      refute File.exists?(path)
    end
  end
end
