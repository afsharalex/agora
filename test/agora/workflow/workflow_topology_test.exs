defmodule Agora.Workflow.WorkflowTopologyTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow.{Builder, Checkpoint, Serializer, WorkflowTopology}

  defp build_workflow do
    Builder.new()
    |> Builder.step(:fetch, fn _input -> {:ok, "fetched"} end,
      name: "Fetch data",
      timeout: 60_000,
      retry: 1
    )
    |> Builder.step(:transform, fn _input -> {:ok, "transformed"} end,
      name: "Transform",
      inputs: [:fetch]
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

  describe "to_workflow/2" do
    test "reconstructs executable workflow with complete handler map" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      fetch_handler = fn _input -> {:ok, "fetched"} end
      transform_handler = fn _input -> {:ok, "transformed"} end

      {:ok, reconstructed} =
        WorkflowTopology.to_workflow(topology,
          handlers: %{fetch: fetch_handler, transform: transform_handler}
        )

      assert map_size(reconstructed.steps) == 2
      assert Map.has_key?(reconstructed.steps, :fetch)
      assert Map.has_key?(reconstructed.steps, :transform)
      assert reconstructed.steps[:fetch].name == "Fetch data"
      assert reconstructed.steps[:fetch].timeout == 60_000
      assert reconstructed.steps[:fetch].retry == 1
      assert reconstructed.steps[:transform].inputs == [:fetch]
    end

    test "reconstructed workflow produces same workflow_hash" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      fetch_handler = fn _input -> {:ok, "fetched"} end
      transform_handler = fn _input -> {:ok, "transformed"} end

      {:ok, reconstructed} =
        WorkflowTopology.to_workflow(topology,
          handlers: %{fetch: fetch_handler, transform: transform_handler}
        )

      assert Checkpoint.workflow_hash(reconstructed) == Checkpoint.workflow_hash(workflow)
    end

    test "returns error with missing handlers" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      # Only provide handler for :fetch, not :transform
      assert {:error, error} =
               WorkflowTopology.to_workflow(topology,
                 handlers: %{fetch: fn _input -> {:ok, "fetched"} end}
               )

      assert error.type == :validation_error
      assert error.message =~ "No handler for step"
    end

    test "returns error with empty handler map" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      assert {:error, error} = WorkflowTopology.to_workflow(topology, handlers: %{})
      assert error.type == :validation_error
    end

    test "restores edge structure" do
      workflow = build_conditional_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      check_handler = fn _input -> {:ok, :ok} end
      notify_handler = fn _input -> {:ok, "notified"} end

      {:ok, reconstructed} =
        WorkflowTopology.to_workflow(topology,
          handlers: %{check: check_handler, notify: notify_handler},
          conditions: %{{:check, :notify} => fn _r -> true end}
        )

      assert length(reconstructed.edges) == 1
      edge = hd(reconstructed.edges)
      assert edge.from == :check
      assert edge.to == :notify
      assert edge.optional == true
      assert is_function(edge.condition, 1)
    end

    test "conditional edges without provided conditions omit condition fn" do
      workflow = build_conditional_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      {:ok, reconstructed} =
        WorkflowTopology.to_workflow(topology,
          handlers: %{
            check: fn _input -> {:ok, :ok} end,
            notify: fn _input -> {:ok, "notified"} end
          }
        )

      edge = hd(reconstructed.edges)
      assert edge.optional == true
      # No condition provided → edge has no condition
      assert edge.condition == nil
    end

    test "with known_step_ids allowlist accepts valid IDs" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      {:ok, _reconstructed} =
        WorkflowTopology.to_workflow(topology,
          handlers: %{
            fetch: fn _input -> {:ok, "fetched"} end,
            transform: fn _input -> {:ok, "transformed"} end
          },
          known_step_ids: [:fetch, :transform]
        )
    end

    test "with known_step_ids rejects unknown IDs" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      # Only allow :fetch, not :transform
      assert {:error, error} =
               WorkflowTopology.to_workflow(topology,
                 handlers: %{
                   fetch: fn _input -> {:ok, "fetched"} end,
                   transform: fn _input -> {:ok, "transformed"} end
                 },
                 known_step_ids: [:fetch]
               )

      assert error.type == :validation_error
      assert error.message =~ "not in known_step_ids"
    end

    test "rejects atoms that don't exist in the atom table" do
      topology = %WorkflowTopology{
        steps: %{
          "this_atom_definitely_does_not_exist_xyz_123" => %{
            id: "this_atom_definitely_does_not_exist_xyz_123",
            name: "Bad step",
            inputs: [],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: nil
          }
        },
        edges: []
      }

      assert {:error, error} =
               WorkflowTopology.to_workflow(topology,
                 handlers: %{}
               )

      assert error.type == :validation_error
      assert error.message =~ "Unknown step ID atom"
    end
  end

  describe "to_workflow!/2" do
    test "returns workflow on success" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      reconstructed =
        WorkflowTopology.to_workflow!(topology,
          handlers: %{
            fetch: fn _input -> {:ok, "fetched"} end,
            transform: fn _input -> {:ok, "transformed"} end
          }
        )

      assert map_size(reconstructed.steps) == 2
    end

    test "raises ArgumentError on failure" do
      workflow = build_workflow()
      {:ok, map} = Serializer.to_map(workflow)
      {:ok, topology} = Serializer.from_map(map)

      assert_raise ArgumentError, fn ->
        WorkflowTopology.to_workflow!(topology, handlers: %{})
      end
    end
  end

  describe "handler registry resolution" do
    defmodule TestRegistry do
      def resolve(_state, "fetch_ref") do
        {:ok, fn _input -> {:ok, "registry_fetched"} end}
      end

      def resolve(_state, "transform_ref") do
        {:ok, fn _input -> {:ok, "registry_transformed"} end}
      end

      def resolve(_state, ref) do
        {:error, Agora.Error.new(:workflow_error, "Unknown ref: #{ref}")}
      end
    end

    test "resolves handlers via registry" do
      topology = %WorkflowTopology{
        steps: %{
          "fetch" => %{
            id: "fetch",
            name: "Fetch",
            inputs: [],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: "fetch_ref"
          },
          "transform" => %{
            id: "transform",
            name: "Transform",
            inputs: ["fetch"],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: "transform_ref"
          }
        },
        edges: [
          %{from: "fetch", to: "transform", optional: false, has_condition: false}
        ]
      }

      {:ok, workflow} =
        WorkflowTopology.to_workflow(topology,
          handler_registry: {TestRegistry, :state}
        )

      assert map_size(workflow.steps) == 2
      assert is_function(workflow.steps[:fetch].handler, 1)
      assert is_function(workflow.steps[:transform].handler, 1)
    end

    test "falls back to handler map when no handler_ref" do
      topology = %WorkflowTopology{
        steps: %{
          "fetch" => %{
            id: "fetch",
            name: "Fetch",
            inputs: [],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: nil
          }
        },
        edges: []
      }

      fallback = fn _input -> {:ok, "fallback"} end

      {:ok, workflow} =
        WorkflowTopology.to_workflow(topology,
          handler_registry: {TestRegistry, :state},
          handlers: %{fetch: fallback}
        )

      assert workflow.steps[:fetch].handler == fallback
    end

    test "registry error falls back to handler map" do
      fallback = fn _input -> {:ok, "fallback"} end

      topology = %WorkflowTopology{
        steps: %{
          "fetch" => %{
            id: "fetch",
            name: "Fetch",
            inputs: [],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: "nonexistent_ref"
          }
        },
        edges: []
      }

      # Registry fails but handler map provides the handler
      {:ok, workflow} =
        WorkflowTopology.to_workflow(topology,
          handler_registry: {TestRegistry, :state},
          handlers: %{fetch: fallback}
        )

      assert workflow.steps[:fetch].handler == fallback
    end

    test "registry error with no handler map entry returns error" do
      topology = %WorkflowTopology{
        steps: %{
          "fetch" => %{
            id: "fetch",
            name: "Fetch",
            inputs: [],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: "nonexistent_ref"
          }
        },
        edges: []
      }

      assert {:error, error} =
               WorkflowTopology.to_workflow(topology,
                 handler_registry: {TestRegistry, :state}
               )

      assert error.type == :validation_error
      assert error.message =~ "No handler for step"
    end
  end

  describe "robustness" do
    test "malformed edge referencing unknown step returns validation error" do
      topology = %WorkflowTopology{
        steps: %{
          "fetch" => %{
            id: "fetch",
            name: "Fetch",
            inputs: [],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: nil
          }
        },
        edges: [
          # Edge references "nonexistent" step which isn't in the topology
          %{from: "fetch", to: "nonexistent", optional: false, has_condition: false}
        ]
      }

      assert {:error, error} =
               WorkflowTopology.to_workflow(topology,
                 handlers: %{fetch: fn _input -> {:ok, "ok"} end}
               )

      assert error.type == :validation_error
      assert error.message =~ "unknown step ID"
    end

    test "malformed input referencing unknown step returns validation error" do
      topology = %WorkflowTopology{
        steps: %{
          "fetch" => %{
            id: "fetch",
            name: "Fetch",
            inputs: ["does_not_exist"],
            outputs: nil,
            timeout: 300_000,
            retry: 0,
            handler_type: "function",
            handler_ref: nil
          }
        },
        edges: []
      }

      assert {:error, error} =
               WorkflowTopology.to_workflow(topology,
                 handlers: %{fetch: fn _input -> {:ok, "ok"} end}
               )

      assert error.type == :validation_error
      assert error.message =~ "unknown input"
    end
  end

  describe "full round-trip" do
    test "serialize → deserialize → reconstruct → execute" do
      # Build original workflow
      original =
        Builder.new()
        |> Builder.step(:greet, fn _input -> {:ok, "hello"} end, name: "Greet")
        |> Builder.step(:shout, fn _input -> {:ok, "HELLO"} end,
          name: "Shout",
          inputs: [:greet]
        )
        |> Builder.sequence([:greet, :shout])
        |> Builder.build!()

      # Serialize to JSON
      {:ok, json} = Serializer.to_json(original)

      # Deserialize back
      {:ok, topology} = Serializer.from_json(json)

      # Reconstruct with new handlers
      {:ok, reconstructed} =
        WorkflowTopology.to_workflow(topology,
          handlers: %{
            greet: fn _input -> {:ok, "hello from reconstructed"} end,
            shout: fn _input -> {:ok, "HELLO FROM RECONSTRUCTED"} end
          }
        )

      # Verify structural equality
      assert map_size(reconstructed.steps) == map_size(original.steps)
      assert length(reconstructed.edges) == length(original.edges)
      assert Checkpoint.workflow_hash(reconstructed) == Checkpoint.workflow_hash(original)

      # Execute the reconstructed workflow
      {:ok, results} = Agora.run_workflow(reconstructed)

      assert {:ok, "hello from reconstructed"} = results[:greet]
      assert {:ok, "HELLO FROM RECONSTRUCTED"} = results[:shout]
    end
  end
end
