defmodule Agora.Workflow.AgentStepTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Message}
  alias Agora.Workflow.{AgentStep, Builder}

  describe "spec/3" do
    test "returns a {id, config} tuple with no opts" do
      config = config()
      spec = AgentStep.spec(:research, config)
      assert spec == {:research, config}
    end

    test "returns a {id, config, opts} tuple with opts" do
      config = config()
      spec = AgentStep.spec(:research, config, timeout: 60_000)
      assert spec == {:research, config, timeout: 60_000}
    end

    test "passes through input_mapper" do
      config = config()
      mapper = fn _results -> "mapped input" end
      spec = AgentStep.spec(:step, config, input_mapper: mapper)
      assert {_, _, opts} = spec
      assert is_function(opts[:input_mapper], 1)
    end

    test "passes through retry" do
      config = config()
      spec = AgentStep.spec(:step, config, retry: 3)
      assert {:step, ^config, [retry: 3]} = spec
    end

    test "passes through inputs" do
      config = config()
      spec = AgentStep.spec(:step, config, inputs: [:a, :b])
      assert {:step, ^config, [inputs: [:a, :b]]} = spec
    end
  end

  describe "integration with Builder.step/2" do
    test "tuple form works with Builder" do
      config = config()
      spec = AgentStep.spec(:step_a, config)

      builder = Builder.new() |> Builder.step(spec)
      {:ok, workflow} = Builder.build(builder)
      assert Map.has_key?(workflow.steps, :step_a)
      assert workflow.steps[:step_a].handler == config
    end

    test "tuple form with opts works with Builder" do
      config = config()
      spec = AgentStep.spec(:step_a, config, timeout: 60_000)

      builder = Builder.new() |> Builder.step(spec)
      {:ok, workflow} = Builder.build(builder)
      assert workflow.steps[:step_a].timeout == 60_000
    end

    test "multiple agent steps can be chained" do
      a = config()
      b = config()

      spec_a = AgentStep.spec(:research, a)
      spec_b = AgentStep.spec(:writing, b)

      builder =
        Builder.new()
        |> Builder.step(spec_a)
        |> Builder.step(spec_b)
        |> Builder.sequence([:research, :writing])

      {:ok, workflow} = Builder.build(builder)
      assert Map.has_key?(workflow.steps, :research)
      assert Map.has_key?(workflow.steps, :writing)
      assert length(workflow.edges) == 1
    end
  end

  describe "integration with workflow execution" do
    test "agent step runs through executor" do
      config = config()
      spec = AgentStep.spec(:agent, config, input_mapper: fn _r -> "Hello agent" end)

      builder = Builder.new() |> Builder.step(spec)
      {:ok, workflow} = Builder.build(builder)
      {:ok, results} = Agora.run_workflow(workflow)

      assert {:ok, %Message{} = msg} = results[:agent]
      assert msg.content =~ "Hello agent"
    end

    test "sequential agent steps pass data" do
      first_config = config()
      second_config = config()

      first_spec = AgentStep.spec(:first, first_config, input_mapper: fn _r -> "step one" end)

      second_spec =
        AgentStep.spec(:second, second_config,
          inputs: [:first],
          input_mapper: fn results ->
            case results[:first] do
              %Message{content: c} -> "Got: #{c}"
              _ -> "no input"
            end
          end
        )

      builder =
        Builder.new()
        |> Builder.step(first_spec)
        |> Builder.step(second_spec)

      {:ok, workflow} = Builder.build(builder)
      {:ok, results} = Agora.run_workflow(workflow)

      assert {:ok, %Message{}} = results[:first]
      assert {:ok, %Message{}} = results[:second]
    end
  end

  defp config do
    AgentConfig.new!(provider: :echo, model: "echo")
  end
end
