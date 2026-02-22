# Composition

Agora provides seven coordination patterns for composing agents, plus hierarchical nesting via agent-as-tool. Each pattern compiles to an existing execution substrate (workflow engine or orchestrator) while preserving all cross-cutting behavior.

## Choosing a Pattern

```
Do your agents need to...

Run in sequence, each building on the last?     → Agora.sequential/3
Run independently in parallel?                   → Agora.parallel/3
Take turns refining through conversation?        → Agora.round_robin/3
Collaborate in shared discussion?                → Agora.group_chat/3
Have a manager delegate to workers?              → Agora.supervisor/4
Execute a dynamic, AI-generated plan?            → Agora.plan/4
Pass control peer-to-peer?                       → Agora.handoff/3
Call other agents as tools (hierarchical)?       → Agora.agent_tool/2
Need a deterministic DAG with checkpoints?       → Agora.run_workflow/2 + AgentStep
Need custom coordination logic?                  → Implement Agora.Orchestrator behaviour
```

## Agent Reference Format

All composition functions accept a keyword list of named agents:

```elixir
agents = [
  researcher: Agora.agent(:anthropic, "claude-sonnet-4-20250514",
    instructions: "You research topics."
  ),
  writer: Agora.agent(:anthropic, "claude-sonnet-4-20250514",
    instructions: "You write articles."
  )
]
```

Keys are atoms (developer-authored, never from model output). Values are `%AgentConfig{}` structs.

## Deterministic Patterns

These patterns run each agent exactly once with no LLM-driven routing.

### `sequential/3` — Pipeline

Each agent runs in order. Each receives the previous agent's output as input.

```elixir
{:ok, results} = Agora.sequential("Research the BEAM VM", [
  researcher: researcher,
  writer: writer,
  editor: editor
])

# results is a map: %{researcher: {:ok, %Message{}}, writer: {:ok, %Message{}}, ...}
```

Returns `{:ok, map()}` where keys are agent names, values are `{:ok, %Message{}}` tuples.

### `parallel/3` — Independent Subtasks

All agents run concurrently. Each receives the same input.

```elixir
{:ok, results} = Agora.parallel("Analyze this text", [
  sentiment: sentiment_agent,
  keywords: keywords_agent,
  summary: summary_agent
])
```

## Autonomous Patterns

These patterns involve multi-turn LLM-driven coordination. Agents persist across turns and share conversation context.

### `round_robin/3` — Iterative Refinement

Agents take turns in order, each building on the previous response.

```elixir
{:ok, response} = Agora.round_robin("Discuss BEAM concurrency", [
  researcher: researcher,
  writer: writer
], termination: Agora.Orchestrator.TerminationCondition.max_turns(4))
```

Returns `{:ok, %Message{}}` — the final message from the orchestration.

### `group_chat/3` — Shared Transcript

All agents see the full conversation transcript. Good for collaborative deliberation.

```elixir
{:ok, response} = Agora.group_chat("Design a database schema", [
  architect: architect,
  reviewer: reviewer,
  security: security_expert
], termination: TerminationCondition.max_turns(6))
```

### `supervisor/4` — Manager Delegates to Workers

A designated supervisor agent delegates tasks to specialist workers via `DELEGATE:name:message` directives.

```elixir
manager = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "Delegate research to analyst and writing to writer using DELEGATE:name:task."
)

{:ok, response} = Agora.supervisor("Analyze and document this data",
  {:manager, manager},
  [analyst: analyst, writer: writer]
)
```

The second argument is a `{name, config}` tuple identifying the supervisor agent.

### `plan/4` — AI-Generated Plan Execution

A planner agent creates a structured plan, assigns steps to workers, and reviews results.

```elixir
planner = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "Create and manage execution plans."
)

{:ok, response} = Agora.plan("Research and write about BEAM",
  {:planner, planner},
  [researcher: researcher, writer: writer]
)
```

### `handoff/3` — Peer-to-Peer Routing

Agents pass control to each other via handoff directives. An agent that returns without a handoff declares the task done.

```elixir
{:ok, response} = Agora.handoff("I have a billing question", [
  triage: triage_agent,
  support: support_agent,
  billing: billing_agent
])
```

The first agent in the list runs first by default. Override with the `:initial` option:

```elixir
Agora.handoff("question", agents, initial: :support)
```

## Agent-as-Tool

`Agora.agent_tool/2` wraps an agent as a tool that other agents can call, enabling hierarchical composition:

```elixir
research_tool = Agora.agent_tool(researcher,
  name: "research_agent",
  description: "Delegates research tasks to a specialized agent."
)

supervisor = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "Use research_agent when you need research.",
  tools: [research_tool]
)

{:ok, response} = Agora.run(supervisor, "Research and summarize BEAM concurrency")
```

### Depth Guard

Nested agent-tool chains have a configurable depth limit (default 3) to prevent runaway recursion:

```elixir
tool = Agora.agent_tool(config, max_depth: 5)
```

## Cross-Cutting Options

All composition functions accept these options, which are forwarded to the underlying substrate:

| Option | Type | Description |
|--------|------|-------------|
| `:cancel_token` | `CancelToken.t()` | Boundary-cooperative cancellation |
| `:context_policy` | `ContextPolicy.t()` | Message compaction strategy |
| `:telemetry_metadata` | `map()` | Custom metadata merged into telemetry events |
| `:termination` | `fun` | When to stop (autonomous patterns only) |
| `:max_turns` | `pos_integer()` | Hard safety limit (autonomous patterns, default 100) |
| `:orchestrator_opts` | `keyword()` | Forwarded to orchestrator init (autonomous patterns) |

### Cancellation

```elixir
token = Agora.CancelToken.new()

task = Task.async(fn ->
  Agora.round_robin("Long discussion", agents,
    cancel_token: token,
    termination: TerminationCondition.max_turns(100)
  )
end)

Process.sleep(5_000)
Agora.CancelToken.cancel(token)
{:error, %Agora.Error{type: :cancelled}} = Task.await(task)
```

### Context Compaction

```elixir
policy = Agora.ContextPolicy.new!(strategy: :sliding_window, window_size: 20)

Agora.round_robin("Topic", agents, context_policy: policy)
```

## Advanced: DAG Workflows

For deterministic pipelines with retries, checkpoints, and complex DAG topologies, use the workflow engine directly with `Agora.Workflow.AgentStep`:

```elixir
alias Agora.Workflow.{AgentStep, Builder}

spec = AgentStep.spec(:research, researcher,
  input_mapper: fn results -> "Research: #{results[:input]}" end
)

workflow = Builder.new() |> Builder.step(spec) |> Builder.build!()
{:ok, results} = Agora.run_workflow(workflow)
```

See the [Workflows](workflows.md) guide for the full Builder API.

## Advanced: Custom Orchestrators

For coordination logic not covered by the built-in patterns, implement the `Agora.Orchestrator` behaviour and use `Agora.start_runner/2`:

```elixir
{:ok, runner} = Agora.start_runner(
  orchestrator: MyApp.CustomOrchestrator,
  agents: agents,
  orchestrator_opts: [custom_option: value]
)

{:ok, response} = Agora.Orchestrator.Runner.run(runner, "task")
Agora.stop_runner(runner)
```

See the [Orchestration](orchestration.md) guide for the behaviour callbacks.

## Limitations

**Streaming**: The composition functions do not currently support streaming progress events. For single-agent streaming, use `Agora.stream/2`. Streaming composition variants will be added in a future release.

## See Also

- [Agents](agents.md) -- Agent definition and lifecycle
- [Workflows](workflows.md) -- Builder API, DAG topologies, checkpoints
- [Orchestration](orchestration.md) -- Custom orchestrator implementation
