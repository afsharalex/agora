defmodule Agora.Workflow.DefinitionTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow

  # --- Section 17: Module scaffolding ---

  describe "use Agora.Workflow.Definition" do
    test "compiles without error" do
      defmodule BasicModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
      end

      assert function_exported?(BasicModule, :__workflow__, 0)
      assert function_exported?(BasicModule, :__workflow_steps__, 0)
    end

    test "with timeout and retry options" do
      defmodule OptsModule do
        use Agora.Workflow.Definition, timeout: 10_000, retry: 2

        step(:a, run: fn _ -> {:ok, 1} end)
      end

      w = OptsModule.__workflow__()
      assert %Workflow{} = w
      assert w.steps[:a].timeout == 10_000
      assert w.steps[:a].retry == 2
    end

    test "rejects invalid use options" do
      assert_raise CompileError, ~r/only accepts :timeout and :retry/, fn ->
        defmodule BadOptsModule do
          use Agora.Workflow.Definition, name: "bad"
        end
      end
    end

    test "basic module with one run: step returns %Workflow{}" do
      defmodule OneStepModule do
        use Agora.Workflow.Definition

        step(:fetch, run: fn _ -> {:ok, "data"} end)
      end

      w = OneStepModule.__workflow__()
      assert %Workflow{} = w
      assert Map.has_key?(w.steps, :fetch)
    end
  end

  # --- Section 18: Module-level step macro ---

  describe "step with do block" do
    test "generates callable function with results access" do
      defmodule DoBlockModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 42} end)

        step :b, after: :a do
          {:ok, val} = results[:a]
          {:ok, val + 1}
        end
      end

      w = DoBlockModule.__workflow__()
      assert %Workflow{} = w

      # Step function is public and callable
      assert {:ok, 43} = DoBlockModule.__agora_step_b__(%{a: {:ok, 42}})
    end

    test "generates function without results (no warning)" do
      defmodule NoResultsModule do
        use Agora.Workflow.Definition

        step :a do
          {:ok, "hello"}
        end
      end

      w = NoResultsModule.__workflow__()
      assert {:ok, "hello"} = NoResultsModule.__agora_step_a__(%{})
      assert %Workflow{} = w
    end

    test "step with options and do block" do
      defmodule OptsDoModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)

        step :b, after: :a, timeout: 5_000 do
          {:ok, val} = results[:a]
          {:ok, val * 2}
        end
      end

      w = OptsDoModule.__workflow__()
      assert w.steps[:b].timeout == 5_000
      assert {:ok, 2} = OptsDoModule.__agora_step_b__(%{a: {:ok, 1}})
    end

    test "nested fn that shadows results uses _results for outer" do
      defmodule ShadowModule do
        use Agora.Workflow.Definition

        step :a do
          # results is not used at the outer level — it's only in a nested fn param
          mapper = fn results -> Map.get(results, :x) end
          {:ok, mapper.(%{x: 1})}
        end
      end

      assert {:ok, 1} = ShadowModule.__agora_step_a__(%{})
    end
  end

  describe "step with run:" do
    test "stores function reference" do
      defmodule RunModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, "from_run"} end)
      end

      w = RunModule.__workflow__()
      assert %Workflow{} = w
      handler = w.steps[:a].handler
      assert {:ok, "from_run"} = handler.(%{})
    end

    test "run: with function capture" do
      defmodule RunCaptureModule do
        use Agora.Workflow.Definition

        step(:a, run: &__MODULE__.my_handler/1)

        def my_handler(_results), do: {:ok, "captured"}
      end

      w = RunCaptureModule.__workflow__()
      assert {:ok, "captured"} = w.steps[:a].handler.(%{})
    end

    test "run: with options" do
      defmodule RunOptsModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)

        step(:b,
          after: :a,
          retry: 3,
          run: fn r ->
            {:ok, val} = r[:a]
            {:ok, val + 1}
          end
        )
      end

      w = RunOptsModule.__workflow__()
      assert w.steps[:b].retry == 3
    end

    test "run: + do block raises compile error" do
      assert_raise CompileError, ~r/cannot have both a do block and run:/, fn ->
        defmodule RunDoModule do
          use Agora.Workflow.Definition

          step :a, run: fn _ -> {:ok, 1} end do
            {:ok, 2}
          end
        end
      end
    end

    test "neither run: nor do block raises compile error" do
      assert_raise CompileError, ~r/requires either a do block or run:/, fn ->
        defmodule NeitherModule do
          use Agora.Workflow.Definition

          step(:a, after: :b)
        end
      end
    end
  end

  describe "step accumulation order" do
    test "multiple steps accumulate in definition order" do
      defmodule OrderModule do
        use Agora.Workflow.Definition

        step(:first, run: fn _ -> {:ok, 1} end)
        step(:second, run: fn _ -> {:ok, 2} end)
        step(:third, run: fn _ -> {:ok, 3} end)
      end

      assert [:first, :second, :third] = OrderModule.__workflow_steps__()
    end
  end

  # --- Section 19: edge, chain, parallel macros ---

  describe "edge macro" do
    test "unconditional edge" do
      defmodule EdgeModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, run: fn _ -> {:ok, 2} end)

        edge(:a, :b)
      end

      w = EdgeModule.__workflow__()
      assert length(w.edges) == 1
      [e] = w.edges
      assert e.from == :a
      assert e.to == :b
      assert e.condition == nil
    end

    test "conditional edge with condition:" do
      defmodule CondEdgeModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, run: fn _ -> {:ok, 2} end)

        edge(:a, :b, condition: fn _ -> true end)
      end

      w = CondEdgeModule.__workflow__()
      [e] = w.edges
      assert e.condition != nil
    end

    test "when: alias for condition:" do
      defmodule WhenEdgeModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, run: fn _ -> {:ok, 2} end)

        edge(:a, :b, when: fn _ -> true end)
      end

      w = WhenEdgeModule.__workflow__()
      [e] = w.edges
      assert e.condition != nil
    end

    test "both condition: and when: raises compile error" do
      assert_raise CompileError, ~r/cannot have both :condition and :when/, fn ->
        defmodule BothEdgeModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)

          edge(:a, :b, condition: fn _ -> true end, when: fn _ -> false end)
        end
      end
    end

    test "optional: true edge" do
      defmodule OptionalEdgeModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, run: fn _ -> {:ok, 2} end)

        edge(:a, :b, optional: true)
      end

      w = OptionalEdgeModule.__workflow__()
      [e] = w.edges
      assert e.optional == true
    end

    test "optional: false edge" do
      defmodule OptionalFalseEdgeModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, run: fn _ -> {:ok, 2} end)

        edge(:a, :b, optional: false)
      end

      w = OptionalFalseEdgeModule.__workflow__()
      [e] = w.edges
      assert e.optional == false
    end

    test "non-boolean optional raises compile error" do
      assert_raise CompileError, ~r/edge :optional must be a boolean/, fn ->
        defmodule BadOptionalEdgeModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)

          edge(:a, :b, optional: "yes")
        end
      end
    end
  end

  describe "chain macro" do
    test "generates sequence edges" do
      defmodule ChainModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, run: fn _ -> {:ok, 2} end)
        step(:c, run: fn _ -> {:ok, 3} end)

        chain([:a, :b, :c])
      end

      w = ChainModule.__workflow__()
      assert length(w.edges) == 2
      froms = Enum.map(w.edges, & &1.from)
      tos = Enum.map(w.edges, & &1.to)
      assert :a in froms
      assert :b in froms
      assert :b in tos
      assert :c in tos
    end
  end

  describe "parallel macro" do
    test "generates fan-out/fan-in edges" do
      defmodule ParallelModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, run: fn _ -> {:ok, 2} end)
        step(:c, run: fn _ -> {:ok, 3} end)
        step(:d, run: fn _ -> {:ok, 4} end)

        parallel([:b, :c], from: :a, to: :d)
      end

      w = ParallelModule.__workflow__()
      # a->b, a->c, b->d, c->d = 4 edges
      assert length(w.edges) == 4
    end
  end

  # --- Section 20: @before_compile generation ---

  describe "__workflow__/0 generation" do
    test "returns valid %Workflow{}" do
      defmodule WorkflowGenModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)

        step :b, after: :a do
          {:ok, val} = results[:a]
          {:ok, val + 1}
        end
      end

      w = WorkflowGenModule.__workflow__()
      assert %Workflow{} = w
      assert Map.has_key?(w.steps, :a)
      assert Map.has_key?(w.steps, :b)
    end

    test "__workflow_steps__/0 returns IDs in definition order" do
      defmodule StepsListModule do
        use Agora.Workflow.Definition

        step(:z, run: fn _ -> {:ok, 1} end)
        step(:a, run: fn _ -> {:ok, 2} end)
        step(:m, run: fn _ -> {:ok, 3} end)
      end

      assert [:z, :a, :m] = StepsListModule.__workflow_steps__()
    end

    test "mixed step forms + edges + chain + parallel" do
      defmodule MixedModule do
        use Agora.Workflow.Definition

        step(:source, run: fn _ -> {:ok, "data"} end)

        step :parse, after: :source do
          {:ok, data} = results[:source]
          {:ok, String.upcase(data)}
        end

        step(:validate,
          run: fn r ->
            {:ok, _} = r[:parse]
            {:ok, :valid}
          end
        )

        step(:store, run: fn _ -> {:ok, :stored} end)
        step(:notify, run: fn _ -> {:ok, :notified} end)

        edge(:parse, :validate)
        chain([:validate, :store])
        parallel([:store, :notify], to: :_sink)

        step(:_sink, run: fn _ -> {:ok, :done} end)
      end

      w = MixedModule.__workflow__()
      assert %Workflow{} = w
      assert map_size(w.steps) == 6
    end
  end

  # --- Section 21: Compile-time validation ---

  describe "compile-time validation" do
    test "duplicate step ID raises CompileError" do
      assert_raise CompileError, ~r/duplicate step ID :a/, fn ->
        defmodule DupStepModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:a, run: fn _ -> {:ok, 2} end)
        end
      end
    end

    test "self-loop raises CompileError" do
      assert_raise CompileError, ~r/self-loop/, fn ->
        defmodule SelfLoopModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          edge(:a, :a)
        end
      end
    end

    test "unconditional cycle raises CompileError" do
      assert_raise CompileError, ~r/cycle/, fn ->
        defmodule CycleModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)

          edge(:a, :b)
          edge(:b, :a)
        end
      end
    end

    test "conditional cycle produces warning, not error" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule ConditionalCycleModule do
            use Agora.Workflow.Definition

            step(:a, run: fn _ -> {:ok, 1} end)
            step(:b, run: fn _ -> {:ok, 2} end)

            edge(:a, :b)
            edge(:b, :a, condition: fn _ -> false end)
          end
        end)

      assert warning =~ "potential cycle involving conditional edges"

      # Module still compiles and works
      w = Agora.Workflow.DefinitionTest.ConditionalCycleModule.__workflow__()
      assert %Workflow{} = w
    end

    test "unknown edge endpoints raise CompileError" do
      assert_raise CompileError, ~r/unknown step IDs/, fn ->
        defmodule UnknownEndpointModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)

          edge(:a, :nonexistent)
        end
      end
    end

    test "unknown input refs raise CompileError" do
      assert_raise CompileError, ~r/unknown step IDs/, fn ->
        defmodule UnknownInputModule do
          use Agora.Workflow.Definition

          step(:a, after: :nonexistent, run: fn _ -> {:ok, 1} end)
        end
      end
    end

    test "step with both condition: and when: raises CompileError" do
      assert_raise CompileError, ~r/cannot have both :condition and :when/, fn ->
        defmodule CondWhenStepModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)

          step(:b,
            after: :a,
            condition: fn _ -> true end,
            when: fn _ -> false end,
            run: fn _ -> {:ok, 2} end
          )
        end
      end
    end

    test "step with condition: but no dependency raises CompileError" do
      assert_raise CompileError, ~r/no :after or :inputs dependency/, fn ->
        defmodule CondNoDepModule do
          use Agora.Workflow.Definition

          step(:a, condition: fn _ -> true end, run: fn _ -> {:ok, 1} end)
        end
      end
    end

    test "step with condition: and multiple dependencies raises CompileError" do
      assert_raise CompileError, ~r/multiple dependencies.*use edge\/3/, fn ->
        defmodule CondMultiDepModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)

          step(:c,
            inputs: [:a, :b],
            condition: fn _ -> true end,
            run: fn _ -> {:ok, 3} end
          )
        end
      end
    end

    test "inputs: bare atom raises CompileError" do
      assert_raise CompileError, ~r/:inputs must be a list of atoms/, fn ->
        defmodule BareAtomInputModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, inputs: :a, run: fn _ -> {:ok, 2} end)
        end
      end
    end

    test "inputs: list with non-atoms raises CompileError" do
      assert_raise CompileError, ~r/:inputs must be a list of atoms/, fn ->
        defmodule NonAtomInputModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, inputs: [1], run: fn _ -> {:ok, 2} end)
        end
      end
    end

    test "parallel without :from or :to raises CompileError" do
      assert_raise CompileError, ~r/requires at least one of :from or :to/, fn ->
        defmodule BadParallelModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)

          parallel([:a, :b], [])
        end
      end
    end

    test "valid workflow compiles without warnings" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule CleanModule do
            use Agora.Workflow.Definition

            step(:a, run: fn _ -> {:ok, 1} end)
            step(:b, after: :a, run: fn r -> r[:a] end)
          end
        end)

      assert output == ""
      w = Agora.Workflow.DefinitionTest.CleanModule.__workflow__()
      assert %Workflow{} = w
    end

    test "cycle via chain edges raises CompileError" do
      assert_raise CompileError, ~r/cycle/, fn ->
        defmodule ChainCycleModule do
          use Agora.Workflow.Definition

          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)

          chain([:a, :b])
          edge(:b, :a)
        end
      end
    end

    test "cycle via after: auto-edges raises CompileError" do
      assert_raise CompileError, ~r/cycle/, fn ->
        defmodule AfterCycleModule do
          use Agora.Workflow.Definition

          step(:a, after: :b, run: fn _ -> {:ok, 1} end)
          step(:b, after: :a, run: fn _ -> {:ok, 2} end)
        end
      end
    end
  end

  # --- Section 22: run_workflow module support (tested after Agora.ex changes) ---

  # --- Section 23: Step testing support ---

  describe "step testing" do
    test "do block step function is directly callable" do
      defmodule TestableModule do
        use Agora.Workflow.Definition

        step(:fetch, run: fn _ -> {:ok, [1, 2, 3]} end)

        step :count, after: :fetch do
          {:ok, items} = results[:fetch]
          {:ok, length(items)}
        end
      end

      # Test the step function in isolation
      assert {:ok, 3} = TestableModule.__agora_step_count__(%{fetch: {:ok, [1, 2, 3]}})
      assert {:ok, 0} = TestableModule.__agora_step_count__(%{fetch: {:ok, []}})
    end

    test "step receives correct results map shape" do
      defmodule ResultsShapeModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, "hello"} end)

        step :b, after: :a do
          {:ok, Map.keys(results)}
        end
      end

      assert {:ok, [:a]} = ResultsShapeModule.__agora_step_b__(%{a: {:ok, "hello"}})
    end

    test "run: step does not generate named function" do
      defmodule NoFnModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
      end

      refute function_exported?(NoFnModule, :__agora_step_a__, 1)
    end
  end

  describe "agent handler via run:" do
    test "AgentConfig step handler executes correctly" do
      defmodule AgentHandlerModule do
        use Agora.Workflow.Definition

        step(:agent_step, run: Agora.AgentConfig.new!(provider: :echo, model: "echo"))
      end

      {:ok, results} = Agora.run_workflow(AgentHandlerModule)
      assert {:ok, %Agora.Message{role: :assistant}} = results[:agent_step]
    end
  end

  # --- Integration ---

  describe "integration" do
    test "workflow executes correctly via Executor" do
      defmodule ExecutableModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 10} end)

        step :b, after: :a do
          {:ok, val} = results[:a]
          {:ok, val * 2}
        end
      end

      w = ExecutableModule.__workflow__()
      {:ok, results} = Agora.Workflow.Executor.run(w)
      assert results[:a] == {:ok, 10}
      assert results[:b] == {:ok, 20}
    end

    test "step_defaults from use propagate to steps" do
      defmodule DefaultsModule do
        use Agora.Workflow.Definition, timeout: 5_000, retry: 1

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, timeout: 10_000, run: fn _ -> {:ok, 2} end)
      end

      w = DefaultsModule.__workflow__()
      assert w.steps[:a].timeout == 5_000
      assert w.steps[:a].retry == 1
      # Per-step override
      assert w.steps[:b].timeout == 10_000
      assert w.steps[:b].retry == 1
    end
  end

  # --- Section 22: Agora.run_workflow/2 module support ---

  describe "Agora.run_workflow/2 with module" do
    test "executes workflow from module atom" do
      defmodule RunWorkflowModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 42} end)
      end

      {:ok, results} = Agora.run_workflow(RunWorkflowModule)
      assert results[:a] == {:ok, 42}
    end

    test "returns error for non-existent module" do
      assert {:error, error} = Agora.run_workflow(NonExistentModule.DoesNotExist)
      assert error.type == :workflow_error
      assert error.message =~ "could not be loaded"
    end

    test "returns error for module without __workflow__/0" do
      assert {:error, error} = Agora.run_workflow(Enum)
      assert error.type == :workflow_error
      assert error.message =~ "does not define __workflow__/0"
    end

    test "passes opts through to executor" do
      defmodule RunWorkflowOptsModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, 1} end)
        step(:b, after: :a, run: fn _ -> {:error, Agora.Error.new(:workflow_error, "fail")} end)
      end

      # With on_failure: :skip, the workflow should still succeed
      {:ok, results} = Agora.run_workflow(RunWorkflowOptsModule, on_failure: :skip)
      assert results[:a] == {:ok, 1}
    end

    test "returns error when __workflow__/0 raises" do
      defmodule RaisingWorkflowModule do
        def __workflow__ do
          raise "boom"
        end
      end

      assert {:error, error} = Agora.run_workflow(RaisingWorkflowModule)
      assert error.type == :workflow_error
      assert error.message =~ "__workflow__/0 raised"
      assert error.message =~ "boom"
    end

    test "existing struct form still works" do
      defmodule StructFormModule do
        use Agora.Workflow.Definition

        step(:a, run: fn _ -> {:ok, "struct"} end)
      end

      w = StructFormModule.__workflow__()
      {:ok, results} = Agora.run_workflow(w)
      assert results[:a] == {:ok, "struct"}
    end
  end
end
