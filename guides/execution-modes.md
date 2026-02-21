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
| `:plan` | `Agora.Orchestrator.Plan` | Autonomous plan-execute-review |
| `:handoff` | `Agora.Orchestrator.Handoff` | Decentralized baton-passing |

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

## Plan Mode

Plan Mode provides autonomous project-manager orchestration. A designated planner agent creates a structured plan, assigns steps to specialist workers, and reviews results with retry/reassign/replan capability.

### Basic Usage

```elixir
{:ok, response} = Agora.run_mode(:plan, "Research and write about BEAM concurrency",
  agents: %{
    planner: planner_config,
    researcher: researcher_config,
    writer: writer_config
  },
  orchestrator_opts: [planner_agent: :planner]
)
```

### How It Works

1. **Planning** — The planner agent receives the task and outputs a structured plan with `PLAN`/`END_PLAN` markers
2. **Executing** — Steps execute in dependency order, each worker receiving focused context
3. **Reviewing** — After each step, the planner reviews and decides: CONTINUE, RETRY, REASSIGN, REPLAN, or COMPLETE

### Plan Format

The planner outputs steps between markers. Dependencies are declared with `:DEP:id`:

```
PLAN
STEP:1:researcher:Research the topic
STEP:2:writer:Write the draft:DEP:1
STEP:3:reviewer:Review and edit:DEP:2
END_PLAN
```

### Review Format

After each step execution, the planner reviews with one directive:

```
REVIEW:COMPLETE:summary text
REVIEW:CONTINUE:reason to proceed
REVIEW:RETRY:reason to retry failed step
REVIEW:REASSIGN:worker_name:reason to reassign
REVIEW:REPLAN:reason to create new plan
```

### Options

Pass these via `:orchestrator_opts`:

| Option | Default | Description |
|--------|---------|-------------|
| `:planner_agent` | required | Atom name of the planner agent |
| `:max_retries_per_step` | `2` | Per-step retry limit |
| `:max_replans` | `2` | How many times the planner can replan |
| `:max_plan_steps` | `10` | Maximum steps in a single plan |
| `:parse_plan` | `nil` | Custom 2-arity plan parser function |
| `:parse_review` | `nil` | Custom 1-arity review parser function |

### Custom Parsers

Override the default parsing with custom functions:

```elixir
custom_plan_parser = fn content, agent_lookup ->
  # Parse your custom format, return {:ok, [step]} or {:error, Error.t()}
  {:ok, [%{id: 1, description: "task", assignee: :worker, deps: []}]}
end

orchestrator_opts: [
  planner_agent: :planner,
  parse_plan: custom_plan_parser
]
```

### Mode Selection Guide

| Use Case | Mode |
|----------|------|
| ETL pipeline, sequential processing | `:sequential` |
| Independent parallel tasks with merge | `:parallel` |
| Input-dependent routing | `:conditional` |
| Complex DAG with mixed topologies | `:dag` |
| LLM-driven multi-agent coordination | Orchestrator modes |
| Autonomous plan-execute-review cycle | `:plan` |
| Peer-to-peer agent routing / triage | `:handoff` |

## Handoff Mode

Handoff Mode provides decentralized baton-passing orchestration. Each agent decides who runs next by emitting a handoff directive. An agent that returns without a handoff is declaring the task done.

### Basic Usage

```elixir
{:ok, response} = Agora.run_mode(:handoff, "I have a billing question",
  agents: %{
    triage: triage_config,
    support: support_config,
    billing: billing_config
  },
  orchestrator_opts: [initial_agent: :triage]
)
```

### How It Works

1. The `:initial_agent` receives the user input
2. Each agent processes its input and either completes (no handoff) or hands off to another agent
3. Handoff carries a message to the next agent as context
4. The chain continues until an agent completes or a safety limit is hit

### Handoff Format

Agents can hand off using metadata (preferred) or a directive in the response content.

**Metadata handoff** (structured, recommended):

```elixir
Message.new(:assistant, "Routing to billing.",
  metadata: %{handoff: %{target: "billing", message: "Customer needs refund help"}})
```

**Directive handoff** (text-based fallback):

```
HANDOFF:billing:Customer needs refund help
```

The directive must appear at the very start of the response content — leading whitespace or prose before `HANDOFF:` will cause it to be treated as task completion. Use metadata handoff when the response includes other content alongside the handoff instruction.

When a custom parser is configured, it fully replaces the default directive format — there is no fallback.

### Options

Pass these via `:orchestrator_opts`:

| Option | Default | Description |
|--------|---------|-------------|
| `:initial_agent` | required | Atom name of the first agent to run |
| `:max_hops` | `10` | Maximum handoffs before error |
| `:no_repeat_window` | `nil` | Sliding window to block recent agent repeats |
| `:allowed_handoff_targets` | `nil` | `%{source => [targets]}` policy map |
| `:parse_handoff` | `nil` | Custom 2-arity parser function |

### Handoff Policy

**Self-handoff**: Blocked by default. To allow, include the agent in its own `allowed_handoff_targets` list.

**Allowed targets**: When configured, agents not present as keys in the map cannot hand off at all (fail-closed). When `nil`, any agent can hand off to any other agent (except self).

**No-repeat window**: When set, prevents handing off to an agent that appeared in the last N holders. When `nil`, loops are bounded only by `max_hops`.

### Custom Parser

Override the default directive parsing with a custom function:

```elixir
custom_parser = fn content, agent_lookup ->
  # Return {:handoff, atom(), String.t()} | :no_handoff | {:error, Error.t()}
  case Regex.run(~r/ROUTE:(\w+):(.+)/s, content) do
    [_, name, msg] ->
      case Map.fetch(agent_lookup, name) do
        {:ok, atom} -> {:handoff, atom, msg}
        :error -> {:error, Error.new(:orchestration_error, "Unknown agent: #{name}")}
      end
    nil -> :no_handoff
  end
end

orchestrator_opts: [
  initial_agent: :triage,
  parse_handoff: custom_parser
]
```

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
