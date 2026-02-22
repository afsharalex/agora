defmodule Agora.Workflow.SerializerTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.{Builder, Checkpoint, Serializer, WorkflowTopology}

  defp build_simple_workflow do
    Builder.new()
    |> Builder.step(:fetch, fn _input -> {:ok, "fetched"} end, name: "Fetch data")
    |> Builder.step(:transform, fn _input -> {:ok, "transformed"} end,
      name: "Transform",
      inputs: [:fetch],
      timeout: 60_000,
      retry: 2
    )
    |> Builder.sequence([:fetch, :transform])
    |> Builder.build!()
  end

  defp build_conditional_workflow do
    Builder.new()
    |> Builder.step(:check, fn _input -> {:ok, :ok} end, name: "Check")
    |> Builder.step(:notify, fn _input -> {:ok, "notified"} end, name: "Notify")
    |> Builder.edge(:check, :notify, condition: fn _r -> true end, optional: true)
    |> Builder.build!()
  end

  describe "to_map/2" do
    test "produces expected JSON structure" do
      workflow = build_simple_workflow()
      {:ok, map} = Serializer.to_map(workflow)

      assert map["_schema_version"] == 1
      assert is_binary(map["_workflow_hash"])
      assert is_map(map["steps"])
      assert is_list(map["edges"])
      assert is_map(map["metadata"])

      # Steps are keyed by string IDs
      assert Map.has_key?(map["steps"], "fetch")
      assert Map.has_key?(map["steps"], "transform")

      fetch_step = map["steps"]["fetch"]
      assert fetch_step["name"] == "Fetch data"
      assert fetch_step["handler_type"] == "function"
      assert fetch_step["handler_ref"] == nil
      assert fetch_step["inputs"] == []

      transform_step = map["steps"]["transform"]
      assert transform_step["name"] == "Transform"
      assert transform_step["inputs"] == ["fetch"]
      assert transform_step["timeout"] == 60_000
      assert transform_step["retry"] == 2
    end

    test "serializes edge metadata" do
      workflow = build_conditional_workflow()
      {:ok, map} = Serializer.to_map(workflow)

      edge = Enum.find(map["edges"], &(&1["from"] == "check" && &1["to"] == "notify"))
      assert edge["optional"] == true
      assert edge["has_condition"] == true
    end

    test "edges without conditions set has_condition to false" do
      workflow = build_simple_workflow()
      {:ok, map} = Serializer.to_map(workflow)

      Enum.each(map["edges"], fn edge ->
        assert edge["has_condition"] == false
      end)
    end

    test "classifies agent handler type" do
      config = Agora.AgentConfig.new!(provider: :echo, model: "echo")

      workflow =
        Builder.new()
        |> Builder.step(:agent_step, config, name: "Agent step")
        |> Builder.build!()

      {:ok, map} = Serializer.to_map(workflow)
      assert map["steps"]["agent_step"]["handler_type"] == "agent"
    end

    test "unknown handler_type preserved in deserialization round-trip" do
      # Simulate a serialized map with unknown handler type
      data = %{
        "_schema_version" => 1,
        "steps" => %{
          "weird" => %{
            "name" => "Weird",
            "inputs" => [],
            "outputs" => nil,
            "timeout" => 300_000,
            "retry" => 0,
            "handler_type" => "unknown",
            "handler_ref" => nil
          }
        },
        "edges" => [],
        "metadata" => %{}
      }

      {:ok, topology} = Serializer.from_map(data)
      assert topology.steps["weird"].handler_type == "unknown"
    end

    test "include_hash: false omits workflow hash" do
      workflow = build_simple_workflow()
      {:ok, map} = Serializer.to_map(workflow, include_hash: false)

      refute Map.has_key?(map, "_workflow_hash")
    end

    test "workflow hash matches Checkpoint.workflow_hash/1" do
      workflow = build_simple_workflow()
      {:ok, map} = Serializer.to_map(workflow)

      assert map["_workflow_hash"] == Checkpoint.workflow_hash(workflow)
    end

    test "metadata is preserved" do
      workflow = %{build_simple_workflow() | metadata: %{"key" => "value"}}
      {:ok, map} = Serializer.to_map(workflow)

      assert map["metadata"] == %{"key" => "value"}
    end
  end

  describe "from_map/2" do
    test "round-trips with to_map/2 (structural equality)" do
      workflow = build_simple_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      assert %WorkflowTopology{} = topology
      assert topology.schema_version == 1
      assert topology.workflow_hash == map["_workflow_hash"]
      assert map_size(topology.steps) == 2

      fetch = topology.steps["fetch"]
      assert fetch.name == "Fetch data"
      assert fetch.handler_type == "function"
      assert fetch.inputs == []

      transform = topology.steps["transform"]
      assert transform.name == "Transform"
      assert transform.inputs == ["fetch"]
      assert transform.timeout == 60_000
      assert transform.retry == 2
    end

    test "deserializes edges correctly" do
      workflow = build_conditional_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      edge = Enum.find(topology.edges, &(&1.from == "check" && &1.to == "notify"))
      assert edge.optional == true
      assert edge.has_condition == true
    end

    test "rejects future schema version" do
      data = %{"_schema_version" => 99, "steps" => %{}, "edges" => []}
      assert {:error, error} = Serializer.from_map(data, [])

      assert error.type == :validation_error
      assert error.message =~ "Unsupported schema version 99"
    end

    test "defaults to schema version 1 when missing" do
      data = %{"steps" => %{}, "edges" => []}
      {:ok, topology} = Serializer.from_map(data)

      assert topology.schema_version == 1
    end

    test "handles empty steps and edges" do
      data = %{"_schema_version" => 1}
      {:ok, topology} = Serializer.from_map(data)

      assert topology.steps == %{}
      assert topology.edges == []
      assert topology.metadata == %{}
    end

    test "preserves metadata" do
      data = %{
        "_schema_version" => 1,
        "steps" => %{},
        "edges" => [],
        "metadata" => %{"env" => "production"}
      }

      {:ok, topology} = Serializer.from_map(data)
      assert topology.metadata == %{"env" => "production"}
    end
  end

  describe "to_json/2 and from_json/2" do
    test "round-trips via JSON string" do
      workflow = build_simple_workflow()
      {:ok, json} = Serializer.to_json(workflow)

      assert is_binary(json)
      {:ok, topology} = Serializer.from_json(json)

      assert %WorkflowTopology{} = topology
      assert map_size(topology.steps) == 2
      assert topology.steps["fetch"].name == "Fetch data"
    end

    test "to_json produces valid JSON" do
      workflow = build_simple_workflow()
      {:ok, json} = Serializer.to_json(workflow)

      assert {:ok, _} = Jason.decode(json)
    end

    test "from_json with invalid JSON returns error" do
      assert {:error, error} = Serializer.from_json("not valid json")
      assert error.type == :workflow_error
      assert error.message =~ "JSON decode failed"
    end
  end

  describe "handler registry integration" do
    defmodule MockRegistry do
      def handler_to_ref(_state, handler) when is_function(handler, 1) do
        {:ok, "mock_ref_fn"}
      end

      def handler_to_ref(_state, _handler) do
        {:error, Agora.Error.new(:workflow_error, "unknown handler")}
      end
    end

    test "to_map with handler_registry populates handler_ref" do
      workflow = build_simple_workflow()
      {:ok, map} = Serializer.to_map(workflow, handler_registry: {MockRegistry, :state})

      assert map["steps"]["fetch"]["handler_ref"] == "mock_ref_fn"
      assert map["steps"]["transform"]["handler_ref"] == "mock_ref_fn"
    end

    test "handler_ref is nil without registry" do
      workflow = build_simple_workflow()
      {:ok, map} = Serializer.to_map(workflow)

      assert map["steps"]["fetch"]["handler_ref"] == nil
    end

    test "registry error falls back to nil handler_ref" do
      config = Agora.AgentConfig.new!(provider: :echo, model: "echo")

      workflow =
        Builder.new()
        |> Builder.step(:agent_step, config)
        |> Builder.build!()

      {:ok, map} = Serializer.to_map(workflow, handler_registry: {MockRegistry, :state})

      # MockRegistry returns error for non-function handlers
      assert map["steps"]["agent_step"]["handler_ref"] == nil
    end
  end

  describe "round-trip with Default registry" do
    # These tests use the real ETS-backed Default registry (from app supervision tree).

    alias Agora.Workflow.HandlerRegistry.Default

    setup do
      :ets.delete_all_objects(Default)
      :ok
    end

    test "full round-trip: serialize with registry → deserialize → reconstruct → run" do
      fetch_handler = fn _input -> {:ok, "fetched_via_registry"} end
      transform_handler = fn _input -> {:ok, "transformed_via_registry"} end

      # Register handlers
      {:ok, _} = Default.register(:default, "fetch_ref", fetch_handler)
      {:ok, _} = Default.register(:default, "transform_ref", transform_handler)

      # Build workflow with the registered handlers
      workflow =
        Builder.new()
        |> Builder.step(:fetch, fetch_handler, name: "Fetch")
        |> Builder.step(:transform, transform_handler, name: "Transform", inputs: [:fetch])
        |> Builder.sequence([:fetch, :transform])
        |> Builder.build!()

      # Serialize with registry
      {:ok, map} = Serializer.to_map(workflow, handler_registry: {Default, :default})

      assert map["steps"]["fetch"]["handler_ref"] == "fetch_ref"
      assert map["steps"]["transform"]["handler_ref"] == "transform_ref"

      # Deserialize
      {:ok, topology} = Serializer.from_map(map)

      # Reconstruct via registry (no handler map needed)
      {:ok, reconstructed} =
        WorkflowTopology.to_workflow(topology, handler_registry: {Default, :default})

      assert map_size(reconstructed.steps) == 2

      # Execute reconstructed workflow
      {:ok, results} = Agora.run_workflow(reconstructed)
      assert {:ok, "fetched_via_registry"} = results[:fetch]
      assert {:ok, "transformed_via_registry"} = results[:transform]
    end

    test "mixed: some steps via registry, some via handler map" do
      fetch_handler = fn _input -> {:ok, "from_registry"} end
      {:ok, _} = Default.register(:default, "fetch_ref", fetch_handler)

      # Build workflow
      workflow =
        Builder.new()
        |> Builder.step(:fetch, fetch_handler, name: "Fetch")
        |> Builder.step(:transform, fn _input -> {:ok, "original"} end,
          name: "Transform",
          inputs: [:fetch]
        )
        |> Builder.sequence([:fetch, :transform])
        |> Builder.build!()

      # Serialize — fetch gets a ref, transform does not (not registered)
      {:ok, map} = Serializer.to_map(workflow, handler_registry: {Default, :default})

      assert map["steps"]["fetch"]["handler_ref"] == "fetch_ref"
      assert map["steps"]["transform"]["handler_ref"] == nil

      # Deserialize
      {:ok, topology} = Serializer.from_map(map)

      # Reconstruct — registry resolves :fetch, handler map provides :transform
      transform_fallback = fn _input -> {:ok, "from_handler_map"} end

      {:ok, reconstructed} =
        WorkflowTopology.to_workflow(topology,
          handler_registry: {Default, :default},
          handlers: %{transform: transform_fallback}
        )

      {:ok, results} = Agora.run_workflow(reconstructed)
      assert {:ok, "from_registry"} = results[:fetch]
      assert {:ok, "from_handler_map"} = results[:transform]
    end
  end

  describe "from_map/2 edge validation" do
    test "returns error for edge missing 'from' key" do
      data = %{
        "_schema_version" => 1,
        "steps" => %{
          "a" => %{"name" => "A", "inputs" => [], "timeout" => 300_000, "retry" => 0}
        },
        "edges" => [%{"to" => "a", "optional" => false}]
      }

      assert {:error, error} = Serializer.from_map(data)
      assert error.type == :validation_error
      assert error.message =~ "from"
    end

    test "returns error for edge missing 'to' key" do
      data = %{
        "_schema_version" => 1,
        "steps" => %{
          "a" => %{"name" => "A", "inputs" => [], "timeout" => 300_000, "retry" => 0}
        },
        "edges" => [%{"from" => "a", "optional" => false}]
      }

      assert {:error, error} = Serializer.from_map(data)
      assert error.type == :validation_error
      assert error.message =~ "to"
    end

    test "returns error for non-map edge entry" do
      data = %{
        "_schema_version" => 1,
        "steps" => %{
          "a" => %{"name" => "A", "inputs" => [], "timeout" => 300_000, "retry" => 0}
        },
        "edges" => [123]
      }

      assert {:error, error} = Serializer.from_map(data)
      assert error.type == :validation_error
      assert error.message =~ "Expected edge to be a map"
    end
  end
end
