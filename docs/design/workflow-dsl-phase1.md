# Workflow DSL — Phase 1: Enhanced Builder

Design specification for ergonomic improvements to `Agora.Workflow.Builder`.

**Status:** Proposed
**Scope:** Function-level additions to Builder. No macros, no executor changes, no new structs.

---

## Motivation

The current Builder API is functional and well-tested, but verbose for common patterns:

```elixir
Builder.new()
|> Builder.step(:fetch, &fetch/1)
|> Builder.step(:transform, &transform/1, inputs: [:fetch])
|> Builder.step(:load, &load/1, inputs: [:transform])
|> Builder.build!()
```

Friction points:

1. `Builder.` prefix on every call (solved by `import`, but not documented/encouraged)
2. `inputs:` is implementation-facing; `after:` reads as intent
3. Linear pipelines require separate `step/4` + `sequence/2` calls that can drift
4. No workflow-level defaults for timeout/retry — repeated on every step
5. Conditional edges require a separate `edge/4` call even for simple single-source conditions
6. Duplicate step IDs silently overwrite via `Map.put`

---

## Design Principles

- **Builder is the single IR.** All authoring sugar compiles down to Builder calls. Future macro DSLs (if built) will also target Builder.
- **Executor is untouched.** No changes to `Executor`, `Step`, `Edge`, or `Workflow` structs.
- **Sugar lives in Builder, not Step.** `Step.new/1` remains a strict data validator. Builder owns authoring ergonomics and normalization.
- **Backward compatible.** All existing Builder code continues to work. New options are additive.

---

## Changes

### 1. `Builder.new/1` with `step_defaults`

Add an optional keyword argument for workflow-wide step defaults.

```elixir
@type t :: %__MODULE__{
        steps: %{atom() => Step.t()},
        edges: [Edge.t()],
        errors: [Error.t()],
        step_defaults: keyword()
      }

defstruct steps: %{}, edges: [], errors: [], step_defaults: []
```

**API:**

```elixir
# Existing (unchanged)
Builder.new()

# New
Builder.new(step_defaults: [timeout: 30_000, retry: 1])
```

**Semantics:** `step_defaults` is stored on the Builder struct. In `step/4`, defaults are merged under per-step opts (per-step opts win):

```elixir
# Effective opts = step_defaults merged with per-step opts
# Keyword.merge(builder.step_defaults, step_opts)
```

**Allowed keys:** Only `:timeout` and `:retry` are accepted in `step_defaults`. All other keys produce a validation error. Rationale: defaults are for execution-policy boilerplate that applies uniformly. Keys like `:name`, `:outputs`, or `:input_mapper` are inherently per-step and would produce surprising behavior if set globally. `Step.new/1` silently ignores unknown keys (it reads only the keys it knows), so Builder must enforce the allowlist — we cannot rely on downstream validation to catch misuse.

---

### 2. `Builder.step/4` enhancements

#### 2a. `after:` alias for `inputs:`

Accepts an atom or list of atoms. Normalized to `inputs:` before passing to `Step.new/1`.

```elixir
# These are equivalent:
Builder.step(b, :transform, &transform/1, inputs: [:fetch])
Builder.step(b, :transform, &transform/1, after: :fetch)
Builder.step(b, :transform, &transform/1, after: [:fetch])
```

**Constraint:** `after:` and `inputs:` together is a validation error. Avoids ambiguous dependency sources.

```elixir
# Error: "Cannot specify both :after and :inputs"
Builder.step(b, :id, &handler/1, after: :a, inputs: [:b])
```

#### 2b. `condition:`/`when:` for inline conditional edges

When `after:` and a condition are both present, Builder generates explicit conditional edges in `step/4` (not deferred to `merge_input_edges/1`).

```elixir
Builder.step(b, :notify, &notify/1,
  after: :analyze,
  condition: fn results -> match?({:ok, n} when n > 100, results[:analyze]) end
)
```

`when:` is accepted as an alias for `condition:` and normalized to `condition:` internally.

**Constraints:**

- `condition:`/`when:` requires a single dependency source — either `after: :atom` or `inputs: [:atom]` (single element). Validation error if neither is present.
- `condition:`/`when:` with multi-element dependency list — validation error regardless of whether `after:` or `inputs:` is used. Multi-dependency conditional logic requires explicit `edge/4` calls.
- `condition:` and `when:` together — validation error.

```elixir
# Error: ":condition/:when requires a single :after or :inputs dependency"
Builder.step(b, :id, &handler/1, condition: fn _ -> true end)

# Error: ":condition/:when with multiple dependencies is not supported; use edge/4"
Builder.step(b, :id, &handler/1, after: [:a, :b], condition: fn _ -> true end)

# Also works with inputs: (legacy style)
Builder.step(b, :notify, &notify/1,
  inputs: [:analyze],
  condition: fn r -> match?({:ok, %{severity: :high}}, r[:analyze]) end
)
```

**Implementation detail:** When a dependency + `condition:` are present, `step/4`:
1. Removes `condition:`/`when:` from opts (Step doesn't know about them)
2. Normalizes `after:` → `inputs:` (if `after:` was used)
3. Calls `Step.new/1` with cleaned opts
4. Generates an explicit edge `{from, to, condition}` via the shared `add_edge/2` helper (see section 4)

Since the edge is explicit, `merge_input_edges/1` already skips generating a duplicate unconditional edge for that `{from, to}` pair. This is the single code path where conditional edges from step sugar are created — there is no other generation site.

#### 2c. Duplicate step ID detection

Error if the step ID already exists in `builder.steps`:

```elixir
# Error: "Step :fetch is already defined"
Builder.new()
|> Builder.step(:fetch, &fetch/1)
|> Builder.step(:fetch, &other_fetch/1)  # error
```

#### 2d. `step_defaults` merging

Per-step opts override workflow defaults:

```elixir
Builder.new(step_defaults: [timeout: 30_000, retry: 1])
|> Builder.step(:fast, &fast/1, timeout: 5_000)  # timeout=5000, retry=1
|> Builder.step(:slow, &slow/1)                   # timeout=30000, retry=1
```

Merge order: `Keyword.merge(builder.step_defaults, step_opts)` — then pass to `Step.new/1`.

---

### 3. `Builder.chain/2`

Defines steps AND linear edges in a single call. Eliminates the common pattern of `step/4` * N + `sequence/2`.

```elixir
@spec chain(t(), [{atom(), Step.handler()} | {atom(), Step.handler(), keyword()}]) :: t()
```

**API:**

```elixir
Builder.new()
|> Builder.chain([
  {:fetch, &fetch/1},
  {:transform, &transform/1},
  {:load, &load/1, retry: 2}
])
|> Builder.build!()
```

**Semantics:**
1. For each tuple, call `step/4` (with step_defaults merging, duplicate detection, etc.)
2. Extract the ordered list of IDs
3. Call `sequence/2` on those IDs to generate linear edges

**Constraint:** Tuple opts containing wiring keys (`:after`, `:inputs`, `:when`, `:condition`) produce a validation error. Chain owns the wiring — it creates a linear sequence. If you need custom wiring, use `step/4` + `edge/4` directly.

```elixir
# Error: "chain/2 does not accept wiring options (:after, :inputs, :when, :condition)"
Builder.chain(b, [
  {:fetch, &fetch/1},
  {:transform, &transform/1, after: :something}  # error
])
```

**Interaction with step_defaults:** Chain tuples benefit from `step_defaults` just like regular `step/4` calls (chain delegates to `step/4` internally).

---

### 4. Centralized edge-add with duplicate detection

All edge additions — `edge/4`, `sequence/2`, `parallel/3`, `step/4` conditional edge generation, and `merge_input_edges/1` auto-edges — go through a single shared private helper:

```elixir
defp add_edge(%__MODULE__{} = builder, %Edge{} = edge) do
  if edge_exists?(builder, edge.from, edge.to) do
    error = Error.new(:workflow_error, "Edge #{inspect(edge.from)} -> #{inspect(edge.to)} already exists")
    %{builder | errors: [error | builder.errors]}
  else
    %{builder | edges: builder.edges ++ [edge]}
  end
end

defp edge_exists?(builder, from, to) do
  Enum.any?(builder.edges, fn e -> e.from == from and e.to == to end)
end
```

**Duplicate definition:** Two edges are duplicates when they share the same `{from, to}` pair, regardless of whether they have different condition functions. A `{from, to}` pair can appear at most once in the edge list. Rationale: multiple conditions on the same edge pair would create ambiguous resolution semantics in the executor.

**What this centralizes:**

| Call site | Currently | After |
|---|---|---|
| `edge/4` | Appends directly | Uses `add_edge/2` |
| `sequence/2` | Appends in reduce | Uses `add_edge/2` |
| `parallel/3` (`build_fan_edges`) | Appends in reduce | Uses `add_edge/2` |
| `step/4` conditional edge | New (generates edge) | Uses `add_edge/2` |
| `merge_input_edges/1` | Skips explicit pairs, appends rest | Uses `add_edge/2` (dedup naturally enforced) |

This ensures uniform duplicate detection across all edge-producing code paths, including `chain/2` (which delegates to `step/4` + `sequence/2`).

---

### 5. Auto-edge generation in `merge_input_edges/1`

Auto-edges are generated for `inputs:` (or `after:`-normalized) declarations that don't already have an explicit edge. The existing `MapSet`-based pre-filter silently skips `{from, to}` pairs that already exist as explicit edges — this is intentional, not an error. A step with `after: :a, condition: fn...` generates both an `inputs: [:a]` declaration (for the Step) and an explicit conditional edge (from `step/4`). The pre-filter ensures `merge_input_edges/1` does not attempt to create a duplicate unconditional auto-edge for that pair.

The `add_edge/2` helper serves as a final defensive guard: any auto-edge that somehow gets past the pre-filter and would duplicate an existing `{from, to}` pair is caught and produces an error. In normal operation this should not happen — the pre-filter handles it — but `add_edge/2` ensures invariants hold even if future code paths are added.

---

## Examples

### Before and after comparison

**Linear pipeline:**

```elixir
# Before
alias Agora.Workflow.Builder

Builder.new()
|> Builder.step(:fetch, &fetch/1)
|> Builder.step(:transform, &transform/1, inputs: [:fetch])
|> Builder.step(:load, &load/1, inputs: [:transform])
|> Builder.build!()

# After
import Agora.Workflow.Builder

new()
|> chain([
  {:fetch, &fetch/1},
  {:transform, &transform/1},
  {:load, &load/1}
])
|> build!()
```

**Fan-out with conditional edge:**

```elixir
# Before
alias Agora.Workflow.Builder

Builder.new()
|> Builder.step(:analyze, &analyze/1)
|> Builder.step(:report, &report/1, inputs: [:analyze])
|> Builder.step(:alert, &alert/1, inputs: [:analyze])
|> Builder.edge(:analyze, :alert, condition: fn r ->
  match?({:ok, %{severity: :high}}, r[:analyze])
end)
|> Builder.build!()

# After
import Agora.Workflow.Builder

new()
|> step(:analyze, &analyze/1)
|> step(:report, &report/1, after: :analyze)
|> step(:alert, &alert/1, after: :analyze, condition: fn r ->
  match?({:ok, %{severity: :high}}, r[:analyze])
end)
|> build!()
```

**Production pipeline with defaults:**

```elixir
import Agora.Workflow.Builder

new(step_defaults: [timeout: 30_000, retry: 1])
|> chain([
  {:fetch_users, &fetch_users/1},
  {:validate, &validate/1},
  {:enrich, &enrich/1, timeout: 60_000}
])
|> step(:notify, &notify/1, after: :enrich, condition: fn r ->
  match?({:ok, %{changes: true}}, r[:enrich])
end)
|> step(:store, &store/1, after: :enrich, retry: 3)
|> build!()
```

---

## Validation Error Summary

Errors are accumulated on the Builder (not raised) and surfaced at `build/1`/`build!/1` time. Test assertions should match on error type (`:workflow_error`) and a key phrase, not exact message strings, to avoid brittle tests.

| Condition | Error type | Key phrase |
|---|---|---|
| `after:` and `inputs:` both present | `:workflow_error` | `"both :after and :inputs"` |
| `condition:`/`when:` without dependency | `:workflow_error` | `"requires a single :after or :inputs"` |
| `condition:` and `when:` both present | `:workflow_error` | `"both :condition and :when"` |
| `condition:`/`when:` with multi-element deps | `:workflow_error` | `"multiple dependencies"` |
| Duplicate step ID | `:workflow_error` | `"already defined"` |
| Duplicate edge `{from, to}` | `:workflow_error` | `"already exists"` |
| Wiring keys in `chain/2` tuple opts | `:workflow_error` | `"wiring options"` |
| Non-allowed keys in `step_defaults` | `:workflow_error` | `"only :timeout and :retry"` |

---

## Test Plan

### Backward compatibility
- All existing Builder tests pass unchanged
- `inputs:` continues to work identically
- `new()` (0-arity) continues to work

### `after:` alias
- `after: :atom` normalizes to `inputs: [:atom]`
- `after: [:a, :b]` normalizes to `inputs: [:a, :b]`
- `after:` + `inputs:` together → error
- Auto-edge generation works with `after:`-defined inputs

### `condition:`/`when:` on step
- Single `after:` + `condition:` generates conditional edge
- Single `after:` + `when:` generates conditional edge (alias)
- Single `inputs:` + `condition:` generates conditional edge (legacy style)
- `condition:` without any dependency → error
- `when:` without any dependency → error
- `condition:` + `when:` together → error
- Multi-element `after:` + `condition:` → error
- Multi-element `inputs:` + `condition:` → error
- `after: [:a]` (single-element list) + `condition:` → works (normalized to single dependency)
- Generated conditional edge silently suppresses auto-edge for same `{from, to}` in `merge_input_edges/1` (pre-filter, no error)
- Condition function evaluated correctly by executor (integration)

### `chain/2`
- 2-tuple `{id, handler}` defines step
- 3-tuple `{id, handler, opts}` defines step with opts
- Linear edges generated between consecutive steps
- Wiring keys in tuple opts → error
- `step_defaults` applied to chain steps
- Duplicate step ID within chain → error
- Empty list → no-op (builder unchanged)
- Single-element list → step defined, no edges

### `step_defaults`
- `new(step_defaults: [...])` stores defaults
- Per-step opts override defaults
- Defaults applied to both `step/4` and `chain/2`
- Wiring keys in defaults → error
- Non-allowed keys in defaults → error (only `:timeout` and `:retry` accepted)

### Duplicate detection
- Duplicate step ID via `step/4` → error
- Duplicate step ID via `chain/2` → error
- Duplicate edge via `edge/4` → error
- Duplicate edge via `sequence/2` → error
- Duplicate edge via `parallel/3` → error
- `step/4` conditional edge + explicit `edge/4` same pair → error
- `chain/2` followed by `chain/2` with overlapping adjacency → error
- Duplicate `{from, to}` with different conditions → still error (pair uniqueness regardless of condition)

---

## Future Phases (deferred)

These are explicitly NOT part of Phase 1. They will only be built if real user demand justifies them.

### Phase 2: Block macro DSL

`Agora.Workflow.DSL` module with `workflow do ... end` macro that compiles to Builder pipeline. Inline `do` blocks for step handlers with injected `results` binding. Includes `~>` operator for visual DAG wiring within the macro scope. Only justified if Phase 1 proves insufficient for common authoring patterns.

**`~>` edge operator** — visual DAG wiring scoped to the `workflow` block. `~>` is in Elixir's parser operator table, so `:a ~> :b` parses to `{:~>, meta, [:a, :b]}` AST without a runtime definition. The `workflow` macro pattern-matches on these AST nodes and emits `Builder.edge/4` calls.

Interpretation rules:

| Form | Expansion | Pattern |
|---|---|---|
| `:a ~> :b` | `edge(:a, :b)` | Single edge |
| `:a ~> :b ~> :c` | `edge(:a, :b)` + `edge(:b, :c)` | Chain |
| `[:a, :b] ~> :c` | `edge(:a, :c)` + `edge(:b, :c)` | Fan-in |
| `:a ~> [:b, :c]` | `edge(:a, :b)` + `edge(:a, :c)` | Fan-out |
| `[:a, :b] ~> [:c, :d]` | **Validation error** | Mixed lists (use explicit `edge/3` or separate `~>` expressions) |

Conditional edges use explicit `edge/3` — attaching conditions to `~>` would defeat its visual clarity purpose.

`~>` and `after:` are complementary: `after:` collocates a dependency with the step that needs it; `~>` shows the topology in a dedicated visual section. A workflow can use either or both.

```elixir
workflow do
  step :fetch do
    {:ok, API.get_users()}
  end

  step :count, after: :fetch, run: &count/1
  step :format, after: :fetch, run: &format/1
  step :summary, run: &summarize/1

  [:count, :format] ~> :summary
end
```

### Phase 3: Module DSL

`use Agora.Workflow.Definition` with `@before_compile` validation. Only justified if workflows become reusable, versioned, production artifacts (similar to Broadway pipelines or Oban workers). Currently workflows are ephemeral data — the `%Workflow{}` struct is the right abstraction.

Compile-time cycle detection: unconditional cycles are compile errors (they can never execute). Cycles involving at least one conditional edge are compile warnings (the condition may break the cycle at runtime).

### Explicitly rejected

| Idea | Reason |
|---|---|
| `join/3` | `after: [...]` already communicates fan-in |
| `agent_step` sugar | Hides AgentConfig complexity users need to understand |
| `input/1` macro | `results[:step_id]` is already one expression |
| `run:` keyword for handler (Phase 1) | Redundant with positional arg in function Builder (accepted in Phase 2 macro DSL where positional args don't apply) |
