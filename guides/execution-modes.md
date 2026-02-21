# Execution Modes

Agora provides a unified `run_mode/3` entry point for executing multi-agent orchestrations and workflows. This guide covers the available modes, their options, and how to use cross-cutting concerns like cancellation and context compaction.

## Mode Taxonomy

Agora organizes execution into two categories:

### Orchestrator Modes

LLM-driven coordination patterns where agents take turns based on an orchestrator's decisions.

| Mode | Module | Description |
|------|--------|-------------|
| `:single` | `Agora.Orchestrator.Single` | Single agent, one turn |
| `:round_robin` | `Agora.Orchestrator.RoundRobin` | Cycle through agents |
| `:group_chat` | `Agora.Orchestrator.GroupChat` | Shared transcript discussion |
| `:supervisor` | `Agora.Orchestrator.Supervisor` | Delegation to workers |

### Workflow Modes

Deterministic pipelines with explicit step dependencies.

| Mode | Input Shape | Description |
|------|-------------|-------------|
| `:dag` | `Workflow.t()` or module | Full DAG execution |
| `:sequential` | `[step_spec()]` | Linear chain (A → B → C) |
| `:conditional` | `{router_spec, [branch_spec()]}` | Router with conditional branches |
| `:parallel` | `[step_spec()]` | Fan-out/fan-in topology |

## Using `run_mode/3`

```elixir
# Orchestrator mode
{:ok, response} = Agora.run_mode(:round_robin, "Discuss this topic",
  agents: %{
    researcher: researcher_config,
    writer: writer_config
  },
  termination: TerminationCondition.max_turns(5)
)

# Workflow mode — full DAG
{:ok, results} = Agora.run_mode(:dag, my_workflow, input: data)

# Workflow mode — sequential pipeline
{:ok, results} = Agora.run_mode(:sequential, [
  {:fetch, &fetch_data/1},
  {:transform, &transform/1},
  {:load, &load/1, timeout: 5_000}
])

# Workflow mode — parallel fan-out/fan-in
{:ok, results} = Agora.run_mode(:parallel,
  [{:analyze, &analyze/1}, {:summarize, &summarize/1}],
  from: {:source, &get_data/1},
  to: {:merge, &combine/1}
)

# Workflow mode — conditional routing
{:ok, results} = Agora.run_mode(:conditional, {
  {:router, &classify/1},
  [
    {fn r -> r[:router] == {:ok, :urgent} end, {:fast_path, &handle_urgent/1}},
    {fn r -> r[:router] == {:ok, :normal} end, {:slow_path, &handle_normal/1}}
  ]
}, merge: {:final, &finalize/1})
```

The function automatically dispatches to the correct execution path based on the mode atom.

## Options

### Orchestrator Mode Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `:agents` | `%{atom() => AgentConfig.t()}` | Yes | Named agent configurations |
| `:termination` | `(context -> :continue \| {:done, Message.t()})` | No | When to stop |
| `:max_turns` | `pos_integer()` | No | Hard safety limit (default 100) |
| `:cancel_token` | `CancelToken.t()` | No | Cancellation signal |
| `:context_policy` | `ContextPolicy.t()` | No | Message compaction strategy |
| `:telemetry_metadata` | `map()` | No | Custom telemetry metadata |
| `:orchestrator_opts` | `keyword()` | No | Forwarded to orchestrator init |

### Workflow Mode Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `:input` | `term()` | No | Initial input data |
| `:on_failure` | `:abort \| :skip` | No | Failure mode |
| `:checkpoint_store` | `{module, keyword()}` | No | Resumability |
| `:cancel_token` | `CancelToken.t()` | No | Boundary-cooperative cancellation |
| `:context_policy` | `ContextPolicy.t()` | No | Injected into AgentConfig steps |
| `:telemetry_metadata` | `map()` | No | Merged into telemetry events |
| `:step_defaults` | `keyword()` | No | Applied to all steps (pattern modes) |
| `:from` | `step_spec()` | No | Source step (`:parallel` mode) |
| `:to` | `step_spec()` | No | Sink step (`:parallel` mode) |
| `:merge` | `step_spec()` | No | Merge step (`:conditional` mode) |

## Workflow Modes

### `:sequential` — Linear Chain

The simplest workflow topology. Steps execute in order, each receiving the results of all previous steps.

```elixir
{:ok, results} = Agora.run_mode(:sequential, [
  {:fetch, fn _r -> {:ok, MyApp.API.get_data()} end},
  {:transform, fn r ->
    {:ok, data} = r[:fetch]
    {:ok, Enum.map(data, &normalize/1)}
  end},
  {:load, fn r ->
    {:ok, records} = r[:transform]
    {:ok, MyApp.DB.insert_all(records)}
  end}
])
```

### `:parallel` — Fan-out/Fan-in

Multiple branches execute concurrently. Use `:from` and `:to` to wire a source and sink step.

```elixir
{:ok, results} = Agora.run_mode(:parallel,
  [{:analyze, &analyze/1}, {:summarize, &summarize/1}],
  from: {:source, &get_data/1},
  to: {:merge, fn r ->
    {:ok, a} = r[:analyze]
    {:ok, s} = r[:summarize]
    {:ok, %{analysis: a, summary: s}}
  end}
)
```

Without `:from`/`:to`, branches run independently in parallel.

### `:conditional` — Router with Branches

A router step produces a result, then condition functions determine which branches execute. Unmatched branches are skipped.

```elixir
{:ok, results} = Agora.run_mode(:conditional, {
  {:classify, fn _r -> {:ok, MyApp.classify(input)} end},
  [
    {fn r -> r[:classify] == {:ok, :urgent} end,
     {:handle_urgent, &MyApp.handle_urgent/1}},
    {fn r -> r[:classify] == {:ok, :normal} end,
     {:handle_normal, &MyApp.handle_normal/1}}
  ]
}, merge: {:report, &MyApp.build_report/1})
```

The optional `:merge` step uses optional edges — it runs when any branch succeeds, but is blocked if a branch fails (not just skipped). This prevents merging partial/bad state.

### `:dag` — Full DAG

For complex topologies, use the Builder API and pass the resulting workflow struct:

```elixir
workflow = Builder.new()
  |> Builder.step(:a, &step_a/1)
  |> Builder.step(:b, &step_b/1, after: :a)
  |> Builder.step(:c, &step_c/1, after: :a)
  |> Builder.step(:d, &step_d/1)
  |> Builder.parallel([:b, :c], to: :d)
  |> Builder.build!()

{:ok, results} = Agora.run_mode(:dag, workflow, input: data)
```

### Mode Selection Guide

| Use Case | Mode |
|----------|------|
| ETL pipeline, sequential processing | `:sequential` |
| Independent parallel tasks with merge | `:parallel` |
| Input-dependent routing | `:conditional` |
| Complex DAG with mixed topologies | `:dag` |
| LLM-driven multi-agent coordination | Orchestrator modes |

## Cancellation

`CancelToken` provides boundary-cooperative cancellation using lock-free atomics:

```elixir
token = Agora.CancelToken.new()

# Start execution in another process
task = Task.async(fn ->
  Agora.run_mode(:round_robin, "Long discussion",
    agents: agents,
    cancel_token: token
  )
end)

# Cancel after some condition
Process.sleep(5_000)
Agora.CancelToken.cancel(token)

{:error, %Agora.Error{type: :cancelled}} = Task.await(task)
```

Cancellation is checked at execution boundaries — it does not interrupt in-flight provider calls or tool executions. This matches the cooperative model used by `Agora.Middleware.Timeout`.

### Cancellation in Workflows

For workflow modes, cancellation is checked at two boundaries:

1. **Before each level starts** — prevents new levels from executing
2. **Inside each spawned task** — prevents individual steps from starting

Cancellation is globally terminal: it overrides `:on_failure` mode (even `:skip`) and cancelled steps are never retried regardless of their `:retry` count.

```elixir
token = CancelToken.new()

{:error, %Error{type: :cancelled}} =
  Agora.run_mode(:sequential, steps,
    cancel_token: token,
    on_failure: :skip  # :skip does NOT prevent cancellation from being terminal
  )
```

## Context Compaction

`ContextPolicy` trims message history to prevent unbounded token growth:

```elixir
# Keep a sliding window of recent messages
policy = Agora.ContextPolicy.new!(
  strategy: :sliding_window,
  window_size: 20
)

# Keep first 2 + last 10 messages
policy = Agora.ContextPolicy.new!(
  strategy: :head_tail,
  head: 2,
  tail: 10
)

Agora.run_mode(:round_robin, "Topic",
  agents: agents,
  context_policy: policy
)
```

For workflow modes, context policy is injected as synthetic middleware into `AgentConfig` step handlers. Pure function handlers are unaffected (they have no provider call to compact).

### Compaction Invariants

These rules are always preserved:

1. The latest user message is never discarded
2. Tool-call + tool-result pairs are kept intact
3. System messages are exempt from compaction (by default)
4. Oldest non-system, non-tool-pair messages are discarded first

## Migration Notes

### ChatRoom to GroupChat

`Agora.Orchestrator.GroupChat` is an alias for `Agora.Orchestrator.ChatRoom`. Both work identically — `GroupChat` aligns with common multi-agent terminology.

```elixir
# These are equivalent:
Agora.run_mode(:group_chat, "Topic", agents: agents)

{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.GroupChat,
  agents: agents
)
```

### Existing APIs

`Agora.run/2`, `Agora.start_runner/2`, and `Agora.run_workflow/2` remain unchanged. `run_mode/3` is additive — use whichever API suits your needs.
