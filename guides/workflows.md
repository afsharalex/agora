# Workflows

Workflows define deterministic pipelines where execution order is predetermined. Unlike orchestrators (LLM-driven routing), workflows follow predefined step dependencies with parallel fan-out, conditional branching, retry, and checkpoint-based resumability.

## Agent-Based Workflows

The simplest way to use workflows is through the composition functions, which run agents as workflow steps.

### Sequential Pipeline

```elixir
researcher = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  name: "researcher", instructions: "You research topics."
)
writer = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  name: "writer", instructions: "You write articles."
)

{:ok, results} = Agora.sequential("Write about BEAM", [
  researcher: researcher,
  writer: writer
])
```

### Parallel Fan-Out

```elixir
{:ok, results} = Agora.parallel("Analyze this text", [
  sentiment: sentiment_agent,
  keywords: keywords_agent,
  summary: summary_agent
])
```

### AgentStep for DAG Workflows

For complex topologies, use `Agora.Workflow.AgentStep` with the Builder API:

```elixir
alias Agora.Workflow.{AgentStep, Builder}

research_spec = AgentStep.spec(:research, researcher,
  input_mapper: fn _results -> "Research the BEAM virtual machine" end
)

writing_spec = AgentStep.spec(:writing, writer,
  input_mapper: fn results ->
    {:ok, msg} = results[:research]
    "Write an article based on: #{msg.content}"
  end
)

workflow =
  Builder.new()
  |> Builder.step(research_spec)
  |> Builder.step(writing_spec)
  |> Builder.sequence([:research, :writing])
  |> Builder.build!()

{:ok, results} = Agora.run_workflow(workflow)
```

## Function-Based Workflows

Steps can also be plain functions for non-LLM logic:

### Build a Linear Workflow

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

### Parallel Fan-Out/Fan-In

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

### Conditional Branching

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

### `after:` alias

```elixir
Builder.step(:transform, fn r -> ... end, after: :fetch)
```

`after: :step_id` is equivalent to `inputs: [:step_id]`. Lists work too: `after: [:a, :b]`.

### `chain/2` for linear pipelines

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

### `step_defaults` for workflow-wide defaults

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

### Inline `condition:`/`when:`

```elixir
Builder.step(:alert, &send_alert/1,
  after: :check,
  condition: fn r -> elem(r[:check], 1) == :critical end
)
```

## Agent-Powered Steps

Use `AgentConfig` as a step handler to run an LLM agent within the workflow:

```elixir
agent_config = Agora.agent(:anthropic, "claude-sonnet-4-20250514")

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
```

## Block DSL

For inline workflow definitions, the `Agora.Workflow.DSL` module provides a `workflow do ... end` macro:

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

  :fetch ~> :transform
end

{:ok, results} = Agora.run_workflow(w)
```

## Module DSL

For reusable workflow modules with compile-time validation:

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
end

{:ok, results} = Agora.run_workflow(MyApp.Workflows.ETL)
```

## Builder API Reference

| Function | Description |
|----------|-------------|
| `Builder.new/0,1` | Create a new builder (with optional `step_defaults`) |
| `Builder.step/2` | Add a pre-built step spec tuple (from `AgentStep.spec/3`) |
| `Builder.step/3,4` | Add a step with handler and options |
| `Builder.edge/3,4` | Add a dependency edge (with optional condition) |
| `Builder.sequence/2` | Chain step IDs into linear edges |
| `Builder.chain/2` | Define steps and wire them in a linear pipeline |
| `Builder.parallel/3` | Fan-out from one step, fan-in to another |
| `Builder.build/1,2` | Build workflow, return `{:ok, workflow} \| {:error, errors}` |
| `Builder.build!/1,2` | Build workflow or raise on validation error |

## Telemetry

Workflows emit telemetry events:

- `[:agora, :workflow, :run, :start | :stop | :exception]` -- workflow-level
- `[:agora, :workflow, :step, :start | :stop | :exception]` -- per-step

## See Also

- [Composition](composition.md) -- High-level agent coordination patterns
- [Agents](agents.md) -- Agent definition and lifecycle
