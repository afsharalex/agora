# Workflow DSL — Implementation TODO

Task breakdown for all phases of the Workflow DSL.

**Branch:** `workflow-dsl`
**Design doc:** `docs/design/workflow-dsl-phase1.md`

---

## Phase 1: Enhanced Builder

### 1. Centralized `add_edge/2` helper

Prerequisite for all other changes. Refactor existing edge-appending code to use a shared private helper with `{from, to}` duplicate detection.

- [x] **1.1** Add `add_edge/2` and `edge_exists?/3` private functions to Builder
- [x] **1.2** Refactor `edge/4` to use `add_edge/2` instead of direct append
- [x] **1.3** Refactor `sequence/2` reduce to use `add_edge/2`
- [x] **1.4** Refactor `parallel/3` (`build_fan_edges/4`) to use `add_edge/2`
- [x] **1.5** Refactor `merge_input_edges/1` to use `add_edge/2` (keep MapSet pre-filter as fast path)
- [x] **1.6** Tests: duplicate edge via `edge/4` → error
- [x] **1.7** Tests: duplicate edge via `sequence/2` → error
- [x] **1.8** Tests: duplicate edge via `parallel/3` → error
- [x] **1.9** Tests: duplicate `{from, to}` with different conditions → error
- [x] **1.10** Tests: all existing Builder tests still pass (backward compat)

### 2. Duplicate step ID detection

- [ ] **2.1** Add duplicate ID check in `step/4` — error if `id` already in `builder.steps`
- [ ] **2.2** Tests: duplicate step ID via `step/4` → error
- [ ] **2.3** Tests: non-duplicate steps still work as before

### 3. `step_defaults` on `Builder.new/1`

- [ ] **3.1** Add `step_defaults` field to Builder struct (default: `[]`)
- [ ] **3.2** Add `new/1` accepting `step_defaults:` keyword option (keep `new/0` unchanged)
- [ ] **3.3** Validate `step_defaults` allowlist — only `:timeout` and `:retry` accepted, all other keys → error
- [ ] **3.4** Merge `step_defaults` under per-step opts in `step/4` (`Keyword.merge(defaults, step_opts)`)
- [ ] **3.5** Tests: `new(step_defaults: [timeout: 30_000])` stores defaults on struct
- [ ] **3.6** Tests: per-step opts override defaults
- [ ] **3.7** Tests: `new()` (0-arity) still works
- [ ] **3.8** Tests: non-allowed keys in defaults → error (e.g., `:name`, `:inputs`)
- [ ] **3.9** Tests: wiring keys in defaults → error (`:after`, `:when`, `:condition`)

### 4. `after:` alias for `inputs:`

- [ ] **4.1** In `step/4`, normalize `after:` to `inputs:` — atom coerced to `[atom]`
- [ ] **4.2** Validate `after:` and `inputs:` are mutually exclusive → error if both present
- [ ] **4.3** Remove `after:` from opts before passing to `Step.new/1`
- [ ] **4.4** Tests: `after: :atom` normalizes to `inputs: [:atom]`
- [ ] **4.5** Tests: `after: [:a, :b]` normalizes to `inputs: [:a, :b]`
- [ ] **4.6** Tests: `after:` + `inputs:` together → error
- [ ] **4.7** Tests: auto-edge generation works with `after:`-defined inputs
- [ ] **4.8** Tests: `inputs:` continues to work unchanged

### 5. `condition:`/`when:` inline conditional edges

- [ ] **5.1** In `step/4`, normalize `when:` to `condition:`
- [ ] **5.2** Validate `condition:` and `when:` are mutually exclusive → error if both present
- [ ] **5.3** Validate `condition:` requires a dependency (`after:` or `inputs:`) → error if absent
- [ ] **5.4** Validate `condition:` with multi-element dependency list → error
- [ ] **5.5** When single dependency + `condition:` present: remove from opts, generate explicit edge via `add_edge/2`
- [ ] **5.6** Tests: single `after:` + `condition:` generates conditional edge
- [ ] **5.7** Tests: single `after:` + `when:` generates conditional edge (alias)
- [ ] **5.8** Tests: single `inputs:` + `condition:` generates conditional edge (legacy style)
- [ ] **5.9** Tests: `after: [:a]` (single-element list) + `condition:` → works
- [ ] **5.10** Tests: `condition:` without any dependency → error
- [ ] **5.11** Tests: `when:` without any dependency → error
- [ ] **5.12** Tests: `condition:` + `when:` together → error
- [ ] **5.13** Tests: multi-element `after:` + `condition:` → error
- [ ] **5.14** Tests: multi-element `inputs:` + `condition:` → error
- [ ] **5.15** Tests: conditional edge suppresses auto-edge for same `{from, to}` in `merge_input_edges/1` (no error, pre-filter handles it)
- [ ] **5.16** Tests: condition function evaluated correctly by executor (integration test)

### 6. `Builder.chain/2`

- [ ] **6.1** Implement `chain/2` — iterate tuples calling `step/4`, then `sequence/2` on IDs
- [ ] **6.2** Support 2-tuple `{id, handler}` and 3-tuple `{id, handler, opts}` formats
- [ ] **6.3** Validate tuple opts do not contain wiring keys (`:after`, `:inputs`, `:when`, `:condition`) → error
- [ ] **6.4** Tests: 2-tuple defines step correctly
- [ ] **6.5** Tests: 3-tuple defines step with opts (e.g., `:retry`, `:timeout`)
- [ ] **6.6** Tests: linear edges generated between consecutive steps
- [ ] **6.7** Tests: wiring keys in tuple opts → error
- [ ] **6.8** Tests: `step_defaults` applied to chain steps
- [ ] **6.9** Tests: duplicate step ID within chain → error
- [ ] **6.10** Tests: empty list → no-op (builder unchanged)
- [ ] **6.11** Tests: single-element list → step defined, no edges
- [ ] **6.12** Tests: `chain/2` followed by `chain/2` with overlapping adjacency → error

### 7. Documentation

- [ ] **7.1** Update `Builder` `@moduledoc` with `after:`, `chain/2`, `step_defaults`, `condition:` examples
- [ ] **7.2** Add `@doc` for `new/1` and `chain/2`
- [ ] **7.3** Update `step/4` `@doc` with new options
- [ ] **7.4** Update `guides/workflows.md` — add "Builder Sugar" section showing `import` pattern, `after:`, `chain/2`, defaults, inline conditions
- [ ] **7.5** Update `examples/workflow.exs` to use `after:` or `chain/2` where it improves clarity
- [ ] **7.6** Verify `mix docs` builds cleanly
- [ ] **7.7** Verify `mix format --check-formatted` passes

### 8. Final verification

- [ ] **8.1** All existing Builder tests pass (backward compatibility)
- [ ] **8.2** `mix compile --warnings-as-errors`
- [ ] **8.3** `mix test` — all tests pass
- [ ] **8.4** `mix format --check-formatted`
- [ ] **8.5** `mix docs` builds cleanly
- [ ] **8.6** `mix hex.build` succeeds

---

## Implementation Order

Tasks should be implemented in this order to minimize dependencies:

1. **Centralized `add_edge/2`** (section 1) — prerequisite for everything
2. **Duplicate step ID detection** (section 2) — small, independent
3. **`step_defaults`** (section 3) — modifies struct + `new/1` + `step/4` merge
4. **`after:` alias** (section 4) — modifies `step/4` option normalization
5. **`condition:`/`when:`** (section 5) — depends on `after:` normalization + `add_edge/2`
6. **`chain/2`** (section 6) — depends on `step/4` enhancements + `sequence/2` via `add_edge/2`
7. **Documentation** (section 7) — after all features are implemented
8. **Final verification** (section 8) — last step

---

## Phase 2: Block Macro DSL

New module `Agora.Workflow.DSL` providing a `workflow do ... end` macro that compiles to Builder pipeline calls. Eliminates pipe threading for inline workflow definitions. Supports `do` blocks for inline step handlers with an injected `results` binding.

**Prerequisite:** Phase 1 complete. All macro expansion targets Builder functions.

**Target usage:**

```elixir
import Agora.Workflow.DSL

w = workflow do
  step :fetch do
    {:ok, MyApp.API.get_users()}
  end

  step :transform, after: :fetch do
    {:ok, users} = results[:fetch]
    {:ok, Enum.map(users, &normalize/1)}
  end

  step :count, after: :fetch, run: &count/1
  step :store, after: :transform, retry: 2, run: &MyApp.DB.store/1
  step :summary, run: &summarize/1

  # Visual DAG wiring
  [:count, :transform] ~> :summary

  edge :transform, :notify, condition: fn r ->
    match?({:ok, %{changed: true}}, r[:transform])
  end
end
```

### 9. `Agora.Workflow.DSL` module scaffolding

- [ ] **9.1** Create `lib/agora/workflow/dsl.ex` with `defmodule Agora.Workflow.DSL`
- [ ] **9.2** Implement `workflow/1` macro that accepts a `do` block
- [ ] **9.3** Block body parsing — collect `step`, `edge`, `chain`, `parallel`, and `~>` AST nodes from the block
- [ ] **9.4** Emit Builder pipeline: `Builder.new(opts) |> Builder.step(...) |> ... |> Builder.build!()`
- [ ] **9.5** Support workflow-level options: `workflow timeout: 30_000, retry: 1 do ... end` → `Builder.new(step_defaults: [...])`
- [ ] **9.6** Tests: basic `workflow do ... end` returns `%Workflow{}`
- [ ] **9.7** Tests: workflow-level options passed as `step_defaults`
- [ ] **9.8** Create `test/agora/workflow/dsl_test.exs` test file

### 10. `step` macro — `do` block form

The `do` block form injects `results` as a binding in the anonymous function body.

```elixir
# User writes:
step :transform, after: :fetch do
  {:ok, users} = results[:fetch]
  {:ok, Enum.map(users, &normalize/1)}
end

# Expands to:
Builder.step(builder, :transform, fn results -> ... end, inputs: [:fetch])
```

- [ ] **10.1** Implement `step` macro with `do` block — wrap body in `fn results -> body end`
- [ ] **10.2** Detect whether `results` is used in body; inject `_results` if unused (suppress compiler warning)
- [ ] **10.3** Support all Phase 1 step options in the macro: `after:`, `condition:`/`when:`, `timeout:`, `retry:`
- [ ] **10.4** Tests: `do` block step with `results` access
- [ ] **10.5** Tests: `do` block step without `results` access (no compiler warning)
- [ ] **10.6** Tests: step options (`after:`, `timeout:`, `retry:`) work in macro form
- [ ] **10.7** Tests: `condition:`/`when:` work in macro form

### 11. `step` macro — `run:` keyword form

For function references where a `do` block is unnecessary.

```elixir
step :store, after: :transform, retry: 2, run: &MyApp.DB.store/1
```

- [ ] **11.1** Implement `step` macro with `run:` keyword — extract handler from opts
- [ ] **11.2** Validate `run:` and `do` block are mutually exclusive → compile error
- [ ] **11.3** Validate `run:` is present or `do` block is present → compile error if neither
- [ ] **11.4** Tests: `run:` with function capture
- [ ] **11.5** Tests: `run:` with anonymous function
- [ ] **11.6** Tests: `run:` + `do` block together → error
- [ ] **11.7** Tests: neither `run:` nor `do` block → error

### 12. `edge` macro

Explicit conditional edge declaration within the `workflow` block.

```elixir
edge :analyze, :notify, condition: fn r ->
  match?({:ok, n} when n > 100, r[:analyze])
end
```

- [ ] **12.1** Implement `edge` macro — expands to `Builder.edge/4`
- [ ] **12.2** Support `condition:` and `when:` alias (same semantics as Builder)
- [ ] **12.3** Tests: unconditional edge
- [ ] **12.4** Tests: conditional edge with `condition:`
- [ ] **12.5** Tests: conditional edge with `when:` alias

### 13. `chain` and `parallel` macros

Sugar macros that delegate to Builder equivalents.

**Naming note:** Phase 1 `Builder.chain/2` takes `[{id, handler}]` tuples (defines steps + wires edges). The Phase 2 macro `chain` takes a list of already-defined step IDs and wires edges only — it expands to `Builder.sequence/2`. The naming is intentionally distinct in the Builder API (`chain/2` = define+wire, `sequence/2` = wire-only) so the macro simply maps to the correct underlying function.

```elixir
workflow do
  step :a, run: &a/1
  step :b, run: &b/1
  step :c, run: &c/1
  step :d, run: &d/1

  chain [:a, :b, :c]            # expands to Builder.sequence/2 (wire-only)
  parallel [:b, :c], from: :a, to: :d
end
```

- [ ] **13.1** Implement `chain` macro — expands to `Builder.sequence/2` (edge-only wiring, steps already defined above)
- [ ] **13.2** Implement `parallel` macro — expands to `Builder.parallel/3`
- [ ] **13.3** Tests: `chain` generates linear edges between pre-defined steps
- [ ] **13.4** Tests: `parallel` generates fan-out/fan-in edges
- [ ] **13.5** Documentation: note that macro `chain` maps to `Builder.sequence/2` (wire-only) not `Builder.chain/2` (define+wire)
- [ ] **13.5** Tests: `chain` + `parallel` combined in one workflow

### 14. `~>` edge operator

Visual DAG wiring scoped to the `workflow` block. `~>` is in Elixir's parser operator table — `:a ~> :b` parses to `{:~>, meta, [:a, :b]}` AST without needing a runtime definition. The `workflow` macro pattern-matches on these AST nodes and emits `Builder.edge/4` calls. Conditional edges use explicit `edge/3` — `~>` is for unconditional topology only.

```elixir
workflow do
  step :fetch, run: &fetch/1
  step :count, run: &count/1
  step :format, run: &format/1
  step :summary, run: &summarize/1

  :fetch ~> :count
  :fetch ~> :format
  [:count, :format] ~> :summary
end
```

Interpretation rules:

| Form | Expansion | Pattern |
|---|---|---|
| `:a ~> :b` | `edge(:a, :b)` | Single edge |
| `:a ~> :b ~> :c` | `edge(:a, :b)` + `edge(:b, :c)` | Chain |
| `[:a, :b] ~> :c` | `edge(:a, :c)` + `edge(:b, :c)` | Fan-in |
| `:a ~> [:b, :c]` | `edge(:a, :b)` + `edge(:a, :c)` | Fan-out |

- [ ] **14.1** Implement `~>` AST recognition in `workflow` macro — match `{:~>, _, [left, right]}` nodes
- [ ] **14.2** Handle single edge: `:a ~> :b` → `Builder.edge(b, :a, :b)`
- [ ] **14.3** Handle chained edges: `:a ~> :b ~> :c` → nested `{:~>, _, [{:~>, _, [:a, :b]}, :c]}` AST, flatten recursively
- [ ] **14.4** Handle fan-in: `[:a, :b] ~> :c` → `Builder.edge` for each source
- [ ] **14.5** Handle fan-out: `:a ~> [:b, :c]` → `Builder.edge` for each target
- [ ] **14.6** Handle mixed: `[:a, :b] ~> [:c, :d]` → validation error (cross-product is surprising; use explicit `edge/3` calls or separate `~>` expressions instead)
- [ ] **14.7** Validate operands are atoms or lists of atoms → clear error for invalid types
- [ ] **14.8** `~>` edges go through `add_edge/2` duplicate detection (same as all other edges)
- [ ] **14.9** Tests: single edge `:a ~> :b`
- [ ] **14.10** Tests: chained `:a ~> :b ~> :c` generates two edges
- [ ] **14.11** Tests: fan-in `[:a, :b] ~> :c`
- [ ] **14.12** Tests: fan-out `:a ~> [:b, :c]`
- [ ] **14.13** Tests: `~>` combined with `after:` on steps — both produce edges, no conflicts
- [ ] **14.14** Tests: `~>` duplicate edge detection
- [ ] **14.15** Tests: mixed lists `[:a, :b] ~> [:c, :d]` → validation error
- [ ] **14.16** Tests: invalid operand types → error

### 15. Error reporting and compile-time diagnostics

Macro-generated code should produce clear error messages traceable to the user's source.

- [ ] **15.1** Preserve source line numbers in macro expansion (use `Macro.escape/2` with `line:`)
- [ ] **15.2** Builder errors at `build!/1` reference meaningful locations (not macro internals)
- [ ] **15.3** Invalid macro usage (e.g., `step` outside `workflow` block) → clear compile error
- [ ] **15.4** Tests: error messages include useful context (step ID, option name)
- [ ] **15.5** Tests: `step` outside `workflow` block → compile error

### 16. Phase 2 integration and documentation

- [ ] **16.1** Integration test: full workflow with mixed `do` block + `run:` steps, edges, `~>` wiring, conditions
- [ ] **16.2** Integration test: DSL workflow executed by `Agora.run_workflow/2`
- [ ] **16.3** Integration test: DSL workflow with `AgentConfig` step handler via `run:`
- [ ] **16.4** Integration test: workflow using both `after:` and `~>` for edges
- [ ] **16.5** Add `@moduledoc` and `@doc` to `Agora.Workflow.DSL`
- [ ] **16.6** Add DSL section to `guides/workflows.md` (including `~>` operator usage)
- [ ] **16.7** Add `examples/workflow_dsl.exs` example script
- [ ] **16.8** Add `Agora.Workflow.DSL` to `groups_for_modules` in `mix.exs`
- [ ] **16.9** Verify `mix compile --warnings-as-errors`
- [ ] **16.10** Verify `mix test` — all tests pass
- [ ] **16.11** Verify `mix docs` builds cleanly

---

## Phase 3: Module DSL

`use Agora.Workflow.Definition` that generates a `__workflow__/0` function returning a compiled `%Workflow{}` struct. Enables reusable, documentable, testable workflow modules. Supports compile-time validation via `@before_compile`.

**Prerequisite:** Phase 1 complete. Phase 2 is NOT required — this compiles directly to Builder calls.

**Target usage:**

```elixir
defmodule MyApp.Workflows.ETL do
  use Agora.Workflow.Definition,
    timeout: 30_000,
    retry: 1

  step :fetch do
    {:ok, MyApp.API.get_users()}
  end

  step :transform, after: :fetch do
    {:ok, users} = results[:fetch]
    {:ok, Enum.map(users, &normalize/1)}
  end

  step :store, after: :transform, retry: 3, run: &MyApp.DB.store/1

  edge :transform, :notify, condition: fn r ->
    match?({:ok, %{changed: true}}, r[:transform])
  end
end

# Usage
{:ok, results} = Agora.run_workflow(MyApp.Workflows.ETL)
```

### 17. `Agora.Workflow.Definition` module scaffolding

- [ ] **17.1** Create `lib/agora/workflow/definition.ex`
- [ ] **17.2** Implement `__using__/1` macro — inject `import` for `step`, `edge`, `chain`, `parallel` macros
- [ ] **17.3** Accept module-level options in `use` (e.g., `timeout:`, `retry:`) → stored as `step_defaults`
- [ ] **17.4** Register `@before_compile Agora.Workflow.Definition` hook
- [ ] **17.5** Initialize module attributes for accumulation: `@__agora_steps__`, `@__agora_edges__`
- [ ] **17.6** Tests: `use Agora.Workflow.Definition` compiles without error
- [ ] **17.7** Create `test/agora/workflow/definition_test.exs` test file

### 18. Module-level `step` macro

Accumulates step definitions via module attributes. Handlers become private functions.

```elixir
# User writes:
step :fetch, timeout: 10_000 do
  {:ok, get_users()}
end

# Expands to:
@__agora_steps__ {
  :fetch,
  [timeout: 10_000],
  :__agora_step_fetch__  # name of generated private function
}

defp __agora_step_fetch__(results) do
  _ = results
  {:ok, get_users()}
end
```

- [ ] **18.1** Implement `step` macro with `do` block — generate private function, accumulate step metadata
- [ ] **18.2** Private function naming: `__agora_step_<id>__/1` to avoid user namespace collisions
- [ ] **18.3** Inject `results` parameter (or `_results` if unused)
- [ ] **18.4** Support `run:` keyword form — store function ref directly, no private function generated
- [ ] **18.5** Support all Phase 1 step options: `after:`, `condition:`/`when:`, `timeout:`, `retry:`
- [ ] **18.6** Tests: `do` block step generates callable private function
- [ ] **18.7** Tests: `run:` keyword step stores function reference
- [ ] **18.8** Tests: step options passed through correctly
- [ ] **18.9** Tests: multiple steps accumulate in definition order

### 19. Module-level `edge`, `chain`, `parallel` macros

- [ ] **19.1** Implement `edge` macro — accumulate edge metadata via `@__agora_edges__`
- [ ] **19.2** Support `condition:` and `when:` alias on edges
- [ ] **19.3** Implement `chain` macro — accumulate sequence declaration
- [ ] **19.4** Implement `parallel` macro — accumulate parallel declaration
- [ ] **19.5** Tests: edges accumulated correctly
- [ ] **19.6** Tests: chain generates sequence declaration
- [ ] **19.7** Tests: parallel generates fan-out/fan-in declarations

### 20. `@before_compile` — compile-time validation and `__workflow__/0` generation

The `@before_compile` callback reads accumulated attributes, constructs a Builder pipeline, and defines `__workflow__/0`.

```elixir
def __before_compile__(env) do
  # Read @__agora_steps__ and @__agora_edges__
  # Build Builder pipeline
  # Call Builder.build!() at compile time
  # Define __workflow__/0 returning the compiled %Workflow{}
end
```

- [ ] **20.1** Implement `__before_compile__/1` callback
- [ ] **20.2** Read accumulated `@__agora_steps__` and `@__agora_edges__` from module
- [ ] **20.3** Construct Builder pipeline from accumulated data
- [ ] **20.4** Apply module-level `step_defaults` from `use` options
- [ ] **20.5** Call `Builder.build!/1` at compile time — compile errors surface as readable messages
- [ ] **20.6** Generate `__workflow__/0` function returning the compiled `%Workflow{}` struct
- [ ] **20.7** Generate `__workflow_steps__/0` returning list of step IDs (introspection helper)
- [ ] **20.8** Tests: `__workflow__/0` returns valid `%Workflow{}`
- [ ] **20.9** Tests: `__workflow_steps__/0` returns step IDs in definition order

### 21. Compile-time validation

Best-effort compile-time checks surfaced as clear compilation errors.

- [ ] **21.1** Duplicate step IDs → compile error (detected via module attribute accumulation)
- [ ] **21.2** Self-loop edges → compile error
- [ ] **21.3** Cycle detection on unconditional edges → compile error (unconditional cycles can never execute)
- [ ] **21.4** Cycle detection on graphs containing conditional edges → compile warning (conditional edges may break the cycle at runtime)
- [ ] **21.5** `condition:`/`when:` constraints (same as Phase 1) → compile error
- [ ] **21.6** Tests: duplicate step ID → compile error with clear message
- [ ] **21.7** Tests: self-loop → compile error
- [ ] **21.8** Tests: unconditional cycle → compile error
- [ ] **21.9** Tests: cycle involving conditional edge → compile warning (not error)
- [ ] **21.10** Tests: valid workflow compiles without warnings

### 22. `Agora.run_workflow/2` module support

Extend the convenience API to accept workflow modules in addition to `%Workflow{}` structs.

```elixir
# Existing (unchanged)
{:ok, results} = Agora.run_workflow(%Workflow{...}, opts)

# New — module atom
{:ok, results} = Agora.run_workflow(MyApp.Workflows.ETL, opts)
```

- [ ] **22.1** Add module atom clause to `Agora.run_workflow/2` — call `module.__workflow__/0`
- [ ] **22.2** Validate module implements `__workflow__/0` → `{:error, %Error{}}` if not
- [ ] **22.3** Add module atom clause to `Agora.Workflow.Executor.run/2` (or handle in `Agora.run_workflow/2` before delegating)
- [ ] **22.4** Tests: `Agora.run_workflow(MyModule)` works
- [ ] **22.5** Tests: `Agora.run_workflow(ModuleWithoutWorkflow)` → error
- [ ] **22.6** Tests: `Agora.run_workflow(MyModule, input: "data")` passes opts through

### 23. Step testing support

Enable testing individual steps in isolation from the workflow.

```elixir
# In test
results = %{fetch: {:ok, ["Alice", "Bob"]}}
assert {:ok, 2} = MyApp.Workflows.ETL.__agora_step_count__(results)
```

- [ ] **23.1** Generated private step functions are testable via module — consider making them public with `@doc false`
- [ ] **23.2** Alternative: add `test_step(module, step_id, results)` helper in a test support module
- [ ] **23.3** Tests: individual step function callable with mock results
- [ ] **23.4** Tests: step function receives correct results map shape

### 24. Phase 3 documentation

- [ ] **24.1** Add `@moduledoc` and `@doc` to `Agora.Workflow.Definition`
- [ ] **24.2** Add Module DSL section to `guides/workflows.md`
- [ ] **24.3** Add `examples/workflow_module.exs` example script
- [ ] **24.4** Add `Agora.Workflow.Definition` to `groups_for_modules` in `mix.exs`
- [ ] **24.5** Document step testing pattern in guide
- [ ] **24.6** Document module-level vs inline DSL tradeoffs in `guides/workflows.md`

### 25. Phase 3 final verification

- [ ] **25.1** All Phase 1 and Phase 2 tests still pass
- [ ] **25.2** `mix compile --warnings-as-errors`
- [ ] **25.3** `mix test` — all tests pass
- [ ] **25.4** `mix format --check-formatted`
- [ ] **25.5** `mix docs` builds cleanly
- [ ] **25.6** `mix hex.build` succeeds

---

## Implementation Order (all phases)

### Phase 1 (Enhanced Builder)

1. Centralized `add_edge/2` (section 1)
2. Duplicate step ID detection (section 2)
3. `step_defaults` (section 3)
4. `after:` alias (section 4)
5. `condition:`/`when:` (section 5)
6. `chain/2` (section 6)
7. Documentation (section 7)
8. Final verification (section 8)

### Phase 2 (Block Macro DSL) — only if Phase 1 proves insufficient

9. Module scaffolding (section 9)
10. `step` macro — `do` block form (section 10)
11. `step` macro — `run:` keyword form (section 11)
12. `edge` macro (section 12)
13. `chain` and `parallel` macros (section 13)
14. `~>` edge operator (section 14)
15. Error reporting (section 15)
16. Integration and documentation (section 16)

### Phase 3 (Module DSL) — only if reusable workflows become a real requirement

17. Module scaffolding (section 17)
18. Module-level `step` macro (section 18)
19. Module-level `edge`, `chain`, `parallel` (section 19)
20. `@before_compile` and `__workflow__/0` (section 20)
21. Compile-time validation (section 21)
22. `Agora.run_workflow/2` module support (section 22)
23. Step testing support (section 23)
24. Documentation (section 24)
25. Final verification (section 25)

---

## Phase gates

- **Phase 2 gate:** Only proceed if Phase 1 users report that pipe-threading and anonymous function ceremony are significant pain points in practice.
- **Phase 3 gate:** Only proceed if workflows become reusable, versioned production artifacts that would benefit from module-level encapsulation and compile-time validation.
