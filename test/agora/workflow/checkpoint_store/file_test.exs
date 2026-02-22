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
      assert error.message =~ ":path or :dir is required"
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

  describe "error type round-trip" do
    test "preserves original error type through serialization", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)

      for type <- [:provider_error, :timeout, :cancelled, :tool_error, :rate_limit, :auth_error] do
        error = Agora.Error.new(type, "test #{type}")
        {:ok, state} = FileBackend.save(state, :"step_#{type}", {:error, error})
        assert {:ok, {:error, loaded}} = FileBackend.load(state, :"step_#{type}")
        assert loaded.type == type, "Expected #{type}, got #{loaded.type}"
        assert loaded.message == "test #{type}"
      end
    end

    test "preserves error metadata through serialization", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      error = Agora.Error.new(:provider_error, "API failed", %{status: 500, retries: 3})
      {:ok, state} = FileBackend.save(state, :step_a, {:error, error})

      assert {:ok, {:error, loaded}} = FileBackend.load(state, :step_a)
      assert loaded.type == :provider_error
      assert loaded.message == "API failed"
      assert loaded.metadata["status"] == 500
      assert loaded.metadata["retries"] == 3
    end

    test "handles old format without metadata field", %{path: path} do
      # Simulate old serialization format (no metadata key)
      old_data = %{
        "step_a" => %{
          "_status" => "error",
          "type" => "timeout",
          "message" => "timed out"
        }
      }

      File.write!(path, Jason.encode!(old_data))
      {:ok, state} = FileBackend.init(path: path)

      assert {:ok, {:error, loaded}} = FileBackend.load(state, :step_a)
      assert loaded.type == :timeout
      assert loaded.message == "timed out"
      assert loaded.metadata == %{}
    end

    test "falls back to :workflow_error for unknown error type string", %{path: path} do
      data = %{
        "step_a" => %{
          "_status" => "error",
          "type" => "nonexistent_error_type",
          "message" => "something"
        }
      }

      File.write!(path, Jason.encode!(data))
      {:ok, state} = FileBackend.init(path: path)

      assert {:ok, {:error, loaded}} = FileBackend.load(state, :step_a)
      assert loaded.type == :workflow_error
    end

    test "serializes non-JSON-encodable metadata values as inspect strings", %{path: path} do
      {:ok, state} = FileBackend.init(path: path)
      error = Agora.Error.new(:tool_error, "failed", %{pid: self(), ref: make_ref()})
      {:ok, state} = FileBackend.save(state, :step_a, {:error, error})

      assert {:ok, {:error, loaded}} = FileBackend.load(state, :step_a)
      assert loaded.type == :tool_error
      assert is_binary(loaded.metadata["pid"])
      assert is_binary(loaded.metadata["ref"])
    end
  end

  describe "dir mode init" do
    test "initializes with valid dir" do
      dir = Path.join(System.tmp_dir!(), "agora_snap_#{random_suffix()}")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, state} = FileBackend.init(dir: dir)
      assert state.mode == :dir
      assert state.dir == dir
      assert File.dir?(dir)
    end

    test "rejects both :path and :dir" do
      assert {:error, error} = FileBackend.init(path: "/tmp/x.json", dir: "/tmp/x")
      assert error.message =~ "mutually exclusive"
    end
  end

  describe "snapshot save and load (dir mode)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "agora_snap_#{random_suffix()}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, state} = FileBackend.init(dir: dir)
      %{state: state, dir: dir}
    end

    test "save and load latest snapshot", %{state: state} do
      workflow = build_test_workflow()
      checkpoint = Agora.Workflow.Checkpoint.new(workflow, id: "chk_test1")

      assert {:ok, state} = FileBackend.save_snapshot(state, checkpoint)

      assert {:ok, loaded} = FileBackend.load_snapshot(state, "chk_test1", :latest)
      assert loaded.id == "chk_test1"
      assert loaded.version == 1
      assert loaded.workflow_hash == checkpoint.workflow_hash
    end

    test "load specific version", %{state: state} do
      workflow = build_test_workflow()
      c1 = Agora.Workflow.Checkpoint.new(workflow, id: "chk_ver")
      c2 = %{c1 | version: 2, status: :completed}

      {:ok, state} = FileBackend.save_snapshot(state, c1)
      {:ok, state} = FileBackend.save_snapshot(state, c2)

      assert {:ok, v1} = FileBackend.load_snapshot(state, "chk_ver", 1)
      assert v1.version == 1
      assert v1.status == :in_progress

      assert {:ok, v2} = FileBackend.load_snapshot(state, "chk_ver", 2)
      assert v2.version == 2
      assert v2.status == :completed
    end

    test "load latest returns highest version", %{state: state} do
      workflow = build_test_workflow()
      c1 = Agora.Workflow.Checkpoint.new(workflow, id: "chk_lat")
      c2 = %{c1 | version: 2}
      c3 = %{c1 | version: 3}

      {:ok, state} = FileBackend.save_snapshot(state, c1)
      {:ok, state} = FileBackend.save_snapshot(state, c2)
      {:ok, state} = FileBackend.save_snapshot(state, c3)

      assert {:ok, latest} = FileBackend.load_snapshot(state, "chk_lat", :latest)
      assert latest.version == 3
    end

    test "load nonexistent returns nil", %{state: state} do
      assert {:ok, nil} = FileBackend.load_snapshot(state, "nonexistent", :latest)
    end

    test "list_snapshots returns latest per checkpoint", %{state: state} do
      workflow = build_test_workflow()
      c1 = Agora.Workflow.Checkpoint.new(workflow, id: "chk_list1")
      c2 = Agora.Workflow.Checkpoint.new(workflow, id: "chk_list2")

      {:ok, state} = FileBackend.save_snapshot(state, c1)
      {:ok, state} = FileBackend.save_snapshot(state, c2)

      assert {:ok, list} = FileBackend.list_snapshots(state)
      ids = Enum.map(list, & &1.id) |> Enum.sort()
      assert ids == ["chk_list1", "chk_list2"]
    end

    test "delete_snapshot removes specific version", %{state: state} do
      workflow = build_test_workflow()
      c1 = Agora.Workflow.Checkpoint.new(workflow, id: "chk_del")
      c2 = %{c1 | version: 2}

      {:ok, state} = FileBackend.save_snapshot(state, c1)
      {:ok, state} = FileBackend.save_snapshot(state, c2)

      {:ok, state} = FileBackend.delete_snapshot(state, "chk_del", 1)

      assert {:ok, nil} = FileBackend.load_snapshot(state, "chk_del", 1)
      assert {:ok, v2} = FileBackend.load_snapshot(state, "chk_del", 2)
      assert v2.version == 2
    end

    test "checkpoint results survive round-trip", %{state: state} do
      workflow = build_test_workflow()
      checkpoint = Agora.Workflow.Checkpoint.new(workflow, id: "chk_results")

      checkpoint =
        Agora.Workflow.Checkpoint.record_level_results(checkpoint, %{
          a: {:ok, "result_a"},
          b: {:error, Agora.Error.new(:timeout, "timed out")}
        })

      {:ok, state} = FileBackend.save_snapshot(state, checkpoint)
      assert {:ok, loaded} = FileBackend.load_snapshot(state, "chk_results", :latest)

      assert loaded.results[:a] == {:ok, "result_a"}
      assert {:error, %Agora.Error{type: :timeout}} = loaded.results[:b]
      assert MapSet.member?(loaded.completed_steps, :a)
      assert MapSet.member?(loaded.failed_steps, :b)
    end
  end

  describe "lock/unlock (dir mode)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "agora_lock_#{random_suffix()}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, state} = FileBackend.init(dir: dir)
      %{state: state}
    end

    test "acquire and release lock", %{state: state} do
      {:ok, state} = FileBackend.lock(state, "chk_lock1")
      {:ok, _state} = FileBackend.unlock(state, "chk_lock1")
    end

    test "lock contention returns error", %{state: state} do
      {:ok, state} = FileBackend.lock(state, "chk_lock2")
      assert {:error, error} = FileBackend.lock(state, "chk_lock2")
      assert error.message =~ "is locked"
    end

    test "stale lock detection", %{state: _state} do
      dir = Path.join(System.tmp_dir!(), "agora_stale_#{random_suffix()}")
      on_exit(fn -> File.rm_rf(dir) end)
      # Use 0 second timeout so any lock is stale
      {:ok, state} = FileBackend.init(dir: dir, lock_timeout: 0)

      {:ok, state} = FileBackend.lock(state, "chk_stale")
      # Need to wait at least 1 second since File.stat time: :posix has second granularity
      Process.sleep(1100)
      # Should succeed because lock is stale
      assert {:ok, _state} = FileBackend.lock(state, "chk_stale")
    end

    test "unlock nonexistent is no-op", %{state: state} do
      assert {:ok, _state} = FileBackend.unlock(state, "nonexistent")
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp build_test_workflow do
    alias Agora.Workflow.Builder

    Builder.new()
    |> Builder.step(:a, fn _ -> {:ok, 1} end)
    |> Builder.step(:b, fn _ -> {:ok, 2} end)
    |> Builder.edge(:a, :b)
    |> Builder.build!()
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

  describe "list_snapshots with custom checkpoint IDs" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "agora_list_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
        )

      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "lists checkpoints with non-chk_ prefixed IDs", %{dir: dir} do
      {:ok, state} = FileBackend.init(dir: dir)

      cp = %Agora.Workflow.Checkpoint{
        id: "my_custom_id",
        workflow_hash: "test_hash",
        version: 1,
        status: :completed,
        results: %{},
        completed_steps: MapSet.new(),
        pending_steps: MapSet.new(),
        failed_steps: MapSet.new(),
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now(),
        otp_major_version: 27,
        metadata: %{}
      }

      {:ok, _} = FileBackend.save_snapshot(state, cp)
      {:ok, snapshots} = FileBackend.list_snapshots(state)

      assert length(snapshots) == 1
      assert hd(snapshots).id == "my_custom_id"
    end

    test "lists mix of chk_ and custom IDs", %{dir: dir} do
      {:ok, state} = FileBackend.init(dir: dir)

      for id <- ["chk_standard", "custom_run_42", "pipeline_abc"] do
        cp = %Agora.Workflow.Checkpoint{
          id: id,
          workflow_hash: "hash_#{id}",
          version: 1,
          status: :in_progress,
          results: %{},
          completed_steps: MapSet.new(),
          pending_steps: MapSet.new(),
          failed_steps: MapSet.new(),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now(),
          otp_major_version: 27,
          metadata: %{}
        }

        {:ok, _} = FileBackend.save_snapshot(state, cp)
      end

      {:ok, snapshots} = FileBackend.list_snapshots(state)
      ids = Enum.map(snapshots, & &1.id) |> Enum.sort()
      assert ids == ["chk_standard", "custom_run_42", "pipeline_abc"]
    end
  end

  describe "version sorting" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "agora_vsort_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
        )

      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "latest correctly selects version 1000+ over version 999", %{dir: dir} do
      {:ok, state} = FileBackend.init(dir: dir)

      base_cp = %Agora.Workflow.Checkpoint{
        id: "vsort_test",
        workflow_hash: "hash",
        status: :in_progress,
        results: %{},
        completed_steps: MapSet.new(),
        pending_steps: MapSet.new(),
        failed_steps: MapSet.new(),
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now(),
        otp_major_version: 27,
        metadata: %{}
      }

      # Save version 999
      {:ok, _} = FileBackend.save_snapshot(state, %{base_cp | version: 999})
      # Save version 1000
      {:ok, _} = FileBackend.save_snapshot(state, %{base_cp | version: 1000})

      # Latest should be 1000, not 999 (which is lexicographically larger for "v999" vs "v1000")
      {:ok, latest} = FileBackend.load_snapshot(state, "vsort_test", :latest)
      assert latest.version == 1000
    end
  end

  describe "dir mode save/load/load_all" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "agora_dirmode_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
        )

      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "save/3 is a no-op in dir mode", %{dir: dir} do
      {:ok, state} = FileBackend.init(dir: dir)

      # Should not crash or create any files
      assert {:ok, ^state} = FileBackend.save(state, :my_step, {:ok, "value"})
    end

    test "load/2 returns nil in dir mode", %{dir: dir} do
      {:ok, state} = FileBackend.init(dir: dir)
      assert {:ok, nil} = FileBackend.load(state, :my_step)
    end

    test "load_all/1 returns empty map in dir mode", %{dir: dir} do
      {:ok, state} = FileBackend.init(dir: dir)
      assert {:ok, %{}} = FileBackend.load_all(state)
    end
  end
end
