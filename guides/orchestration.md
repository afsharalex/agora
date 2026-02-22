# Orchestration

> **Primary entry point:** For built-in coordination patterns, use the composition functions
> (`Agora.round_robin/3`, `Agora.supervisor/4`, `Agora.group_chat/3`, etc.).
> See the [Composition](composition.md) guide. This guide covers advanced topics:
> custom orchestrator implementation, termination conditions, and direct Runner lifecycle.

## Built-in Orchestrators

| Orchestrator | Composition Function | Description |
|-------------|---------------------|-------------|
| `Agora.Orchestrator.Single` | `Agora.run/2` | Runs one agent to completion |
| `Agora.Orchestrator.RoundRobin` | `Agora.round_robin/3` | Cycles through agents, each receives previous response |
| `Agora.Orchestrator.Supervisor` | `Agora.supervisor/4` | One agent delegates to workers via `DELEGATE:name:message` |
| `Agora.Orchestrator.ChatRoom` | `Agora.group_chat/3` | Shared transcript -- all agents see the full conversation |
| `Agora.Orchestrator.Plan` | `Agora.plan/4` | Autonomous plan-execute-review cycle |
| `Agora.Orchestrator.Handoff` | `Agora.handoff/3` | Decentralized baton-passing between agents |

`Agora.Orchestrator.GroupChat` is an alias for `ChatRoom`.

## Termination Conditions

Composable closures that determine when orchestration should stop:

```elixir
alias Agora.Orchestrator.TerminationCondition

# Stop after N turns
TerminationCondition.max_turns(10)

# Stop when response contains a keyword
TerminationCondition.keyword_match(["DONE", "FINAL ANSWER"])

# Custom condition
TerminationCondition.custom(fn context ->
  length(context.history) > 5 && some_check?(context)
end)

# Compose with any_of / all_of
TerminationCondition.any_of([
  TerminationCondition.max_turns(10),
  TerminationCondition.keyword_match(["DONE"])
])
```

## Direct Runner Lifecycle

For advanced use cases requiring direct lifecycle management, use the Runner API:

```elixir
alias Agora.Orchestrator.Runner

agents = %{
  researcher: researcher_config,
  writer: writer_config
}

{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.RoundRobin,
  agents: agents,
  termination: TerminationCondition.keyword_match(["FINAL ANSWER"])
)

{:ok, response} = Runner.run(runner, "Research and write about BEAM concurrency")
Agora.stop_runner(runner)
```

## Implement a Custom Orchestrator

```elixir
defmodule MyApp.Orchestrator.Priority do
  @behaviour Agora.Orchestrator

  @impl true
  def init(config) do
    # config is a map with :agent_names (list of atoms) plus any keys
    # from :orchestrator_opts. Access custom options directly from config.
    {:ok, %{agent_names: config.agent_names, priority_order: config[:priority]}}
  end

  @impl true
  def next(state, context) do
    agent = pick_next_agent(state, context)
    input = build_input(context)
    {:next, agent, input, state}
  end

  @impl true
  def handle_result(state, _agent_name, {:ok, message}) do
    if done?(message) do
      {:done, message, state}
    else
      {:continue, state}
    end
  end

  def handle_result(state, _agent_name, {:error, error}) do
    {:error, error, state}
  end
end

# Custom orchestrators use the Runner API directly:
# {:ok, runner} = Runner.start_link(
#   orchestrator: MyApp.Orchestrator.Priority,
#   agents: agents,
#   orchestrator_opts: [priority: [:analyst, :writer]]
# )
# {:ok, response} = Runner.run(runner, "task")
```

The orchestrator behaviour has three callbacks:
- `init/1` -- Initialize state from a map containing `:agent_names` and any `:orchestrator_opts`
- `next/2` -- Pick next agent and input message
- `handle_result/3` -- Process agent result, decide to continue or stop

## Supervisor Delegation

One supervisor agent delegates tasks to named workers using a `DELEGATE:name:message` protocol:

```elixir
manager = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "You are a manager. Delegate tasks using DELEGATE:worker_name:task message."
)

{:ok, response} = Agora.supervisor("Analyze and document this data",
  {:manager, manager},
  [analyst: analyst_config, writer: writer_config]
)
```

## Plan Mode

Plan Mode provides autonomous plan-execute-review orchestration. A designated planner agent creates a structured plan, assigns steps to specialist workers, and reviews results.

### Plan Format

The planner outputs steps between markers:

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

### Plan Options

Pass via `:orchestrator_opts`:

| Option | Default | Description |
|--------|---------|-------------|
| `:planner_agent` | required | Atom name of the planner agent |
| `:max_retries_per_step` | `2` | Per-step retry limit |
| `:max_replans` | `2` | How many times the planner can replan |
| `:max_plan_steps` | `10` | Maximum steps in a single plan |
| `:parse_plan` | `nil` | Custom 2-arity plan parser function |
| `:parse_review` | `nil` | Custom 1-arity review parser function |

## Handoff Mode

Handoff Mode provides decentralized baton-passing orchestration.

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

### Handoff Options

Pass via `:orchestrator_opts`:

| Option | Default | Description |
|--------|---------|-------------|
| `:initial_agent` | required | Atom name of the first agent to run |
| `:max_hops` | `10` | Maximum handoffs before error |
| `:no_repeat_window` | `nil` | Sliding window to block recent agent repeats |
| `:allowed_handoff_targets` | `nil` | `%{source => [targets]}` policy map |
| `:parse_handoff` | `nil` | Custom 2-arity parser function |

## Safety

The Runner enforces a hard `max_turns` limit (default 100) separate from termination conditions, preventing runaway orchestration loops.

## See Also

- [Composition](composition.md) -- High-level coordination patterns
- [Agents](agents.md) -- Agent definition and lifecycle
