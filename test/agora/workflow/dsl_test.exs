defmodule Agora.Workflow.DSLTest do
  use ExUnit.Case, async: true

  alias Agora.Workflow

  # Section 9: Module scaffolding

  describe "workflow/1 basics" do
    test "basic workflow returns %Workflow{}" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
        end

      assert %Workflow{} = w
      assert Map.has_key?(w.steps, :a)
    end

    test "workflow with options passed as step_defaults" do
      import Agora.Workflow.DSL

      w =
        workflow timeout: 10_000 do
          step(:a, run: fn _ -> {:ok, 1} end)
        end

      assert %Workflow{} = w
      assert w.steps[:a].timeout == 10_000
    end

    test "workflow with multiple step_defaults" do
      import Agora.Workflow.DSL

      w =
        workflow timeout: 10_000, retry: 2 do
          step(:a, run: fn _ -> {:ok, 1} end)
        end

      assert w.steps[:a].timeout == 10_000
      assert w.steps[:a].retry == 2
    end

    test "empty workflow builds successfully" do
      import Agora.Workflow.DSL

      w =
        workflow do
        end

      assert %Workflow{} = w
    end
  end

  # Section 10: step do block form

  describe "step with do block" do
    test "step body with results access" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 42} end)

          step :b, after: :a do
            {:ok, val} = results[:a]
            {:ok, val + 1}
          end
        end

      assert %Workflow{} = w
      assert Map.has_key?(w.steps, :b)

      # Verify the handler works
      handler = w.steps[:b].handler
      assert {:ok, 43} = handler.(%{a: {:ok, 42}})
    end

    test "step body without results access (no compiler warning)" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step :a do
            {:ok, "hello"}
          end
        end

      assert %Workflow{} = w
      handler = w.steps[:a].handler
      assert {:ok, "hello"} = handler.(%{})
    end

    test "step body with results rebound inside nested fn is not detected" do
      import Agora.Workflow.DSL

      # The nested fn rebinds `results` in its params — different scope.
      # Should bind _results for the outer fn to avoid unused variable warning.
      w =
        workflow do
          step :a do
            mapper = fn results -> results * 2 end
            {:ok, mapper.(21)}
          end
        end

      handler = w.steps[:a].handler
      assert {:ok, 42} = handler.(%{})
    end

    test "step body with results captured by nested closure (not rebound)" do
      import Agora.Workflow.DSL

      # The nested fn does NOT rebind results — it captures from outer scope.
      # Must detect results usage so outer fn binds `results`, not `_results`.
      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 42} end)

          step :b, after: :a do
            f = fn -> results[:a] end
            {:ok, f.()}
          end
        end

      handler = w.steps[:b].handler
      assert {:ok, {:ok, 42}} = handler.(%{a: {:ok, 42}})
    end

    test "step body with results in closure with other params" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 99} end)

          step :b, after: :a do
            f = fn key -> results[key] end
            {:ok, f.(:a)}
          end
        end

      handler = w.steps[:b].handler
      assert {:ok, {:ok, 99}} = handler.(%{a: {:ok, 99}})
    end

    test "step body with results in destructuring fn param" do
      import Agora.Workflow.DSL

      # fn {results, x} -> ... end shadows results — should NOT detect
      w =
        workflow do
          step :a do
            f = fn {results, x} -> results + x end
            {:ok, f.({1, 2})}
          end
        end

      handler = w.steps[:a].handler
      assert {:ok, 3} = handler.(%{})
    end

    test "step body with pinned results in fn param is not shadowing" do
      import Agora.Workflow.DSL

      # fn ^expected -> ... end pins the outer binding — it's a reference,
      # not a rebinding. Must detect results usage in the outer scope.
      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 42} end)

          step :b, after: :a do
            expected = results[:a]
            f = fn ^expected -> :match end
            {:ok, f.(expected)}
          end
        end

      handler = w.steps[:b].handler
      assert {:ok, :match} = handler.(%{a: {:ok, 42}})
    end

    test "step body with results in case expression" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, :go} end)

          step :b, after: :a do
            case results[:a] do
              {:ok, :go} -> {:ok, "went"}
              _ -> {:ok, "stayed"}
            end
          end
        end

      handler = w.steps[:b].handler
      assert {:ok, "went"} = handler.(%{a: {:ok, :go}})
    end

    test "step do block with options" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)

          step :b, after: :a, timeout: 5_000, retry: 2 do
            {:ok, results[:a]}
          end
        end

      assert w.steps[:b].timeout == 5_000
      assert w.steps[:b].retry == 2
    end

    test "step do block with condition:" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, true} end)

          step :b, after: :a, condition: fn r -> r[:a] == {:ok, true} end do
            {:ok, "conditional"}
          end
        end

      assert %Workflow{} = w
      # Condition generates an edge
      assert length(w.edges) == 1
      assert hd(w.edges).condition != nil
    end

    test "step do block with when:" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, true} end)

          step :b, after: :a, when: fn r -> r[:a] == {:ok, true} end do
            {:ok, "conditional"}
          end
        end

      assert %Workflow{} = w
      assert length(w.edges) == 1
      assert hd(w.edges).condition != nil
    end
  end

  # Section 11: step run: keyword form

  describe "step with run: keyword" do
    test "run: with function capture" do
      import Agora.Workflow.DSL

      handler = fn _ -> {:ok, "captured"} end

      w =
        workflow do
          step(:a, run: handler)
        end

      assert %Workflow{} = w
      assert w.steps[:a].handler == handler
    end

    test "run: with anonymous function" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, "anon"} end)
        end

      assert {:ok, "anon"} = w.steps[:a].handler.(%{})
    end

    test "run: with options" do
      import Agora.Workflow.DSL

      w =
        workflow do
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

      assert w.steps[:b].retry == 3
      assert w.steps[:b].inputs == [:a]
    end

    test "run: + do block together raises CompileError" do
      assert_raise CompileError, ~r/cannot have both a do block and run:/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          step :a, run: fn _ -> {:ok, 1} end do
            {:ok, 2}
          end
        end
        """)
      end
    end

    test "neither run: nor do block raises CompileError" do
      assert_raise CompileError, ~r/requires either a do block or run:/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          step :a, after: :b
        end
        """)
      end
    end
  end

  # Section 12: edge macro

  describe "edge macro" do
    test "unconditional edge" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          edge(:a, :b)
        end

      assert length(w.edges) == 1
      [e] = w.edges
      assert e.from == :a
      assert e.to == :b
      assert e.condition == nil
    end

    test "conditional edge with condition:" do
      import Agora.Workflow.DSL

      cond_fn = fn r -> r[:a] == {:ok, true} end

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, true} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          edge(:a, :b, condition: cond_fn)
        end

      [e] = w.edges
      assert e.condition == cond_fn
    end

    test "conditional edge with when: alias" do
      import Agora.Workflow.DSL

      cond_fn = fn r -> r[:a] == {:ok, true} end

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, true} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          edge(:a, :b, when: cond_fn)
        end

      [e] = w.edges
      assert e.condition == cond_fn
    end

    test "edge with both condition: and when: raises CompileError" do
      assert_raise CompileError, ~r/cannot have both :condition and :when/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          step :a, run: fn _ -> {:ok, 1} end
          step :b, run: fn _ -> {:ok, 2} end
          edge :a, :b, condition: fn _ -> true end, when: fn _ -> true end
        end
        """)
      end
    end

    test "optional edge" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          edge(:a, :b, optional: true)
        end

      [e] = w.edges
      assert e.optional == true
    end

    test "optional: false edge" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          edge(:a, :b, optional: false)
        end

      [e] = w.edges
      assert e.optional == false
    end

    test "optional edge with condition" do
      import Agora.Workflow.DSL

      cond_fn = fn _r -> true end

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          edge(:a, :b, optional: true, condition: cond_fn)
        end

      [e] = w.edges
      assert e.optional == true
      assert e.condition == cond_fn
    end

    test "optional: non-boolean raises CompileError" do
      assert_raise CompileError, ~r/edge :optional must be a boolean/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          step :a, run: fn _ -> {:ok, 1} end
          step :b, run: fn _ -> {:ok, 2} end
          edge :a, :b, optional: "yes"
        end
        """)
      end
    end

    test "edge with non-keyword opts raises CompileError" do
      assert_raise CompileError, ~r/edge options must be a keyword list/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          step :a, run: fn _ -> {:ok, 1} end
          step :b, run: fn _ -> {:ok, 2} end
          edge :a, :b, "invalid"
        end
        """)
      end
    end
  end

  # Section 13: chain and parallel macros

  describe "chain macro" do
    test "generates linear edges between pre-defined steps" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          chain([:a, :b, :c])
        end

      assert length(w.edges) == 2
      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :b} in edges
      assert {:b, :c} in edges
    end
  end

  describe "parallel macro" do
    test "generates fan-out/fan-in edges" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          step(:d, run: fn _ -> {:ok, 4} end)
          parallel([:b, :c], from: :a, to: :d)
        end

      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :b} in edges
      assert {:a, :c} in edges
      assert {:b, :d} in edges
      assert {:c, :d} in edges
    end

    test "chain + parallel combined in one workflow" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          step(:d, run: fn _ -> {:ok, 4} end)
          step(:e, run: fn _ -> {:ok, 5} end)
          chain([:a, :b])
          parallel([:c, :d], from: :b, to: :e)
        end

      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :b} in edges
      assert {:b, :c} in edges
      assert {:b, :d} in edges
      assert {:c, :e} in edges
      assert {:d, :e} in edges
    end
  end

  # Section 14: ~> edge operator

  describe "~> operator" do
    test "single edge :a ~> :b" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          :a ~> :b
        end

      assert length(w.edges) == 1
      [e] = w.edges
      assert {e.from, e.to} == {:a, :b}
    end

    test "chained :a ~> :b ~> :c generates two edges" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          :a ~> :b ~> :c
        end

      assert length(w.edges) == 2
      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :b} in edges
      assert {:b, :c} in edges
    end

    test "fan-in [:a, :b] ~> :c" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          [:a, :b] ~> :c
        end

      assert length(w.edges) == 2
      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :c} in edges
      assert {:b, :c} in edges
    end

    test "fan-out :a ~> [:b, :c]" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          :a ~> [:b, :c]
        end

      assert length(w.edges) == 2
      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :b} in edges
      assert {:a, :c} in edges
    end

    test "~> combined with after: on steps — both produce edges, no conflicts" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, after: :a, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          :b ~> :c
        end

      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :b} in edges
      assert {:b, :c} in edges
    end

    test "~> duplicate edge detection" do
      import Agora.Workflow.DSL

      assert_raise ArgumentError, ~r/already exists/, fn ->
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          :a ~> :b
          :a ~> :b
        end
      end
    end

    test "list-to-list [:a, :b] ~> [:c, :d] raises CompileError" do
      assert_raise CompileError, ~r/list-to-list/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          step :a, run: fn _ -> {:ok, 1} end
          step :b, run: fn _ -> {:ok, 2} end
          step :c, run: fn _ -> {:ok, 3} end
          step :d, run: fn _ -> {:ok, 4} end
          [:a, :b] ~> [:c, :d]
        end
        """)
      end
    end

    test "invalid operand type raises CompileError" do
      assert_raise CompileError, ~r/operands must be atoms or lists of atoms/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          step :a, run: fn _ -> {:ok, 1} end
          "string" ~> :a
        end
        """)
      end
    end
  end

  # Section 15: Error reporting

  describe "error reporting" do
    test "unexpected expression in workflow raises CompileError" do
      assert_raise CompileError, ~r/unexpected expression/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL

        workflow do
          IO.puts("hello")
        end
        """)
      end
    end

    test "step outside workflow raises CompileError" do
      assert_raise CompileError, ~r/step can only be used inside a workflow/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL
        step :a, run: fn _ -> {:ok, 1} end
        """)
      end
    end

    test "edge outside workflow raises CompileError" do
      assert_raise CompileError, ~r/edge can only be used inside a workflow/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL
        edge :a, :b
        """)
      end
    end

    test "chain outside workflow raises CompileError" do
      assert_raise CompileError, ~r/chain can only be used inside a workflow/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL
        chain [:a, :b]
        """)
      end
    end

    test "parallel outside workflow raises CompileError" do
      assert_raise CompileError, ~r/parallel can only be used inside a workflow/, fn ->
        Code.eval_string("""
        import Agora.Workflow.DSL
        parallel [:a, :b], from: :x, to: :y
        """)
      end
    end
  end

  # Section 16: Integration tests

  describe "integration" do
    test "full workflow with mixed forms, edges, ~> wiring, conditions" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step :fetch do
            {:ok, [1, 2, 3]}
          end

          step(:count,
            after: :fetch,
            run: fn r ->
              {:ok, list} = r[:fetch]
              {:ok, length(list)}
            end
          )

          step :double, after: :fetch do
            {:ok, list} = results[:fetch]
            {:ok, Enum.map(list, &(&1 * 2))}
          end

          step(:summary,
            run: fn r ->
              {:ok, count} = r[:count]
              {:ok, doubled} = r[:double]
              {:ok, %{count: count, doubled: doubled}}
            end
          )

          [:count, :double] ~> :summary
        end

      assert %Workflow{} = w
      assert map_size(w.steps) == 4
      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:fetch, :count} in edges
      assert {:fetch, :double} in edges
      assert {:count, :summary} in edges
      assert {:double, :summary} in edges
    end

    test "DSL workflow executed by Agora.run_workflow/2" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step :a do
            {:ok, 10}
          end

          step :b, after: :a do
            {:ok, val} = results[:a]
            {:ok, val * 2}
          end

          step :c, after: :b do
            {:ok, val} = results[:b]
            {:ok, val + 1}
          end
        end

      {:ok, results} = Agora.run_workflow(w)
      assert results[:a] == {:ok, 10}
      assert results[:b] == {:ok, 20}
      assert results[:c] == {:ok, 21}
    end

    test "workflow using both after: and ~> for distinct edges" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, after: :a, run: fn _ -> {:ok, 2} end)
          step(:c, run: fn _ -> {:ok, 3} end)
          step(:d, run: fn _ -> {:ok, 4} end)
          :b ~> :c
          :c ~> :d
        end

      edges = Enum.map(w.edges, fn e -> {e.from, e.to} end)
      assert {:a, :b} in edges
      assert {:b, :c} in edges
      assert {:c, :d} in edges
    end

    test "after: + ~> for same pair — auto-edge deduplicates against explicit" do
      import Agora.Workflow.DSL

      # after: creates auto-edge at build time; ~> creates explicit edge.
      # merge_input_edges skips auto-edges that duplicate explicit edges.
      w =
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, after: :a, run: fn _ -> {:ok, 2} end)
          :a ~> :b
        end

      assert %Workflow{} = w
      assert length(w.edges) == 1
    end

    test "duplicate explicit edges raise" do
      import Agora.Workflow.DSL

      assert_raise ArgumentError, ~r/already exists/, fn ->
        workflow do
          step(:a, run: fn _ -> {:ok, 1} end)
          step(:b, run: fn _ -> {:ok, 2} end)
          edge(:a, :b)
          :a ~> :b
        end
      end
    end

    test "conditional workflow execution" do
      import Agora.Workflow.DSL

      w =
        workflow do
          step(:check, run: fn _ -> {:ok, :go} end)

          step(:proceed, run: fn _ -> {:ok, "went"} end)

          edge(:check, :proceed,
            condition: fn r ->
              r[:check] == {:ok, :go}
            end
          )
        end

      {:ok, results} = Agora.run_workflow(w)
      assert results[:check] == {:ok, :go}
      assert results[:proceed] == {:ok, "went"}
    end

    test "DSL workflow with AgentConfig step handler via run:" do
      import Agora.Workflow.DSL

      agent_config = Agora.AgentConfig.new!(provider: :echo, model: "echo")

      w =
        workflow do
          step(:data, run: fn _ -> {:ok, "raw data"} end)

          step(:agent,
            run: agent_config,
            after: :data,
            input_mapper: fn r ->
              {:ok, data} = r[:data]
              "Analyze: #{data}"
            end
          )
        end

      {:ok, results} = Agora.run_workflow(w)
      assert {:ok, %Agora.Message{content: content}} = results[:agent]
      assert content =~ "Analyze: raw data"
    end
  end
end
