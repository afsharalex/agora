# Workflows

How to build deterministic DAG-based pipelines with parallel execution, conditional branching, and checkpoints.

## Overview

Workflows define deterministic pipelines where execution order is predetermined. Unlike orchestrators (LLM-driven routing), workflows follow predefined step dependencies with parallel fan-out, conditional branching, retry, and checkpoint-based resumability.

## Build a Linear Workflow

```elixir
alias Agora.Workflow.Builder

workflow =
  Builder.new()
  |> Builder.step(:fetch, fn _results -> {:ok, fetch_data()} end)
  |> Builder.step(:transform, fn results ->
    {:ok, data} = results[:fetch]
    {:ok, transform(data)}
  end)
  |> Builder.step(:save, fn results ->
    {:ok, data} = results[:transform]
    {:ok, save(data)}
  end)
  |> Builder.sequence([:fetch, :transform, :save])
  |> Builder.build!()

{:ok, results} = Agora.run_workflow(workflow)
```

## Parallel Fan-Out/Fan-In

Steps within the same topological level execute in parallel:

```elixir
workflow =
  Builder.new()
  |> Builder.step(:source, fn _r -> {:ok, raw_data} end)
  |> Builder.step(:analyze, fn r ->
    {:ok, data} = r[:source]
    {:ok, analyze(data)}
  end)
  |> Builder.step(:summarize, fn r ->
    {:ok, data} = r[:source]
    {:ok, summarize(data)}
  end)
  |> Builder.step(:combine, fn r ->
    {:ok, analysis} = r[:analyze]
    {:ok, summary} = r[:summarize]
    {:ok, merge(analysis, summary)}
  end)
  |> Builder.parallel([:analyze, :summarize], from: :source, to: :combine)
  |> Builder.build!()
```

`parallel/3` creates edges from `:source` to both `:analyze` and `:summarize`, and from both to `:combine`.

## Conditional Branching

Edges can have condition functions that control whether a step executes:

```elixir
workflow =
  Builder.new()
  |> Builder.step(:check, fn _r -> {:ok, "go_a"} end)
  |> Builder.step(:path_a, fn _r -> {:ok, "took path A"} end)
  |> Builder.step(:path_b, fn _r -> {:ok, "took path B"} end)
  |> Builder.edge(:check, :path_a, condition: fn r ->
    {:ok, val} = r[:check]
    val == "go_a"
  end)
  |> Builder.edge(:check, :path_b, condition: fn r ->
    {:ok, val} = r[:check]
    val == "go_b"
  end)
  |> Builder.build!()
```

Steps with unsatisfied conditions are skipped (result is `:skipped`).

## Auto-Edges from Inputs

Declare `inputs` on a step to auto-generate dependency edges:

```elixir
workflow =
  Builder.new()
  |> Builder.step(:a, fn _r -> {:ok, 1} end)
  |> Builder.step(:b, fn _r -> {:ok, 2} end)
  |> Builder.step(:c, fn r ->
    {:ok, a} = r[:a]
    {:ok, b} = r[:b]
    {:ok, a + b}
  end, inputs: [:a, :b])
  |> Builder.build!()
```

## Builder Sugar

The Builder provides several conveniences for common patterns.

### `after:` alias

Use `after:` instead of `inputs:` for more readable dependency declarations:

```elixir
workflow =
  Builder.new()
  |> Builder.step(:fetch, fn _r -> {:ok, fetch_data()} end)
  |> Builder.step(:transform, fn r ->
    {:ok, data} = r[:fetch]
    {:ok, transform(data)}
  end, after: :fetch)
  |> Builder.step(:save, fn r ->
    {:ok, data} = r[:transform]
    {:ok, save(data)}
  end, after: :transform)
  |> Builder.build!()
```

`after: :step_id` is equivalent to `inputs: [:step_id]`. Lists work too: `after: [:a, :b]`.

### `chain/2` for linear pipelines

For simple linear pipelines, `chain/2` defines steps and wires them in one call:

```elixir
workflow =
  Builder.new()
  |> Builder.chain([
    {:fetch, &fetch_data/1},
    {:transform, &transform/1},
    {:load, &load/1, timeout: 5_000}
  ])
  |> Builder.build!()
```

Each element is `{id, handler}` or `{id, handler, opts}`. Wiring options (`:after`, `:inputs`, `:condition`, `:when`) are not allowed since `chain/2` manages the topology.

### `step_defaults` for workflow-wide defaults

Set default `:timeout` and `:retry` for all steps:

```elixir
workflow =
  Builder.new(step_defaults: [timeout: 30_000, retry: 2])
  |> Builder.chain([
    {:fetch, &fetch_data/1},
    {:transform, &transform/1},
    {:load, &load/1}  # inherits timeout: 30_000, retry: 2
  ])
  |> Builder.build!()
```

Per-step options override defaults.

### Inline `condition:`/`when:`

For single-dependency conditional edges, declare the condition inline on the step:

```elixir
workflow =
  Builder.new()
  |> Builder.step(:check, &check_status/1)
  |> Builder.step(:alert, &send_alert/1,
    after: :check,
    condition: fn r -> elem(r[:check], 1) == :critical end
  )
  |> Builder.build!()
```

This is equivalent to calling `Builder.edge(:check, :alert, condition: ...)` separately. Use `edge/4` directly for multi-dependency conditional edges.

## Agent-Powered Steps

Use `AgentConfig` as a step handler to run an LLM agent within the workflow:

```elixir
agent_config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514"
)

workflow =
  Builder.new()
  |> Builder.step(:data, fn _r -> {:ok, "raw data here"} end)
  |> Builder.step(:agent, agent_config,
    input_mapper: fn r ->
      {:ok, data} = r[:data]
      "Analyze this data: #{data}"
    end)
  |> Builder.sequence([:data, :agent])
  |> Builder.build!()
```

The `input_mapper` function converts workflow results into the agent's input message. A temporary agent is started, runs, and is stopped automatically.

## Step Options

```elixir
Builder.step(:my_step, handler_fn,
  inputs: [:dep_a, :dep_b],   # auto-generate edges from these steps
  outputs: %{},                # documentation only (not enforced)
  timeout: 30_000,             # per-step timeout in ms
  retry: 3                     # retry count on failure
)
```

## Failure Modes

```elixir
# :abort (default) -- fail fast on first step failure
{:ok, results} = Agora.run_workflow(workflow, on_failure: :abort)

# :skip -- continue past failures, failed steps return :skipped for dependents
{:ok, results} = Agora.run_workflow(workflow, on_failure: :skip)
```

## Checkpoint Persistence

Resume workflows from where they left off:

```elixir
# In-memory checkpoints (useful for testing)
{:ok, results} = Agora.run_workflow(workflow,
  checkpoint_store: {Agora.Workflow.CheckpointStore.Memory, []}
)

# File-based checkpoints (persists across restarts)
{:ok, results} = Agora.run_workflow(workflow,
  checkpoint_store: {Agora.Workflow.CheckpointStore.File, path: "/tmp/workflow.json"}
)

# With namespace for multiple workflow runs
{:ok, results} = Agora.run_workflow(workflow,
  checkpoint_store: {Agora.Workflow.CheckpointStore.File,
    path: "/tmp/workflows.json", namespace: "run_42"}
)
```

When a checkpoint store is provided, completed steps are loaded from the store and skipped. New step results are saved as they complete.

## Builder API Reference

| Function | Description |
|----------|-------------|
| `Builder.new/0,1` | Create a new builder (with optional `step_defaults`) |
| `Builder.step/3,4` | Add a step with handler and options (`after:`, `condition:`, etc.) |
| `Builder.edge/3,4` | Add a dependency edge (with optional condition) |
| `Builder.sequence/2` | Chain step IDs into linear edges |
| `Builder.chain/2` | Define steps and wire them in a linear pipeline |
| `Builder.parallel/3` | Fan-out from one step, fan-in to another |
| `Builder.build/1` | Build workflow, return `{:ok, workflow} \| {:error, errors}` |
| `Builder.build!/1` | Build workflow or raise on validation error |

## Telemetry

Workflows emit telemetry events:

- `[:agora, :workflow, :run, :start | :stop | :exception]` -- workflow-level
- `[:agora, :workflow, :step, :start | :stop | :exception]` -- per-step
