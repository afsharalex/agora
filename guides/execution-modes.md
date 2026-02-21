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

Deterministic, DAG-based pipelines with explicit step dependencies.

| Mode | Description |
|------|-------------|
| `:dag` | Directed acyclic graph execution |

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

# Workflow mode
{:ok, results} = Agora.run_mode(:dag, my_workflow, input: data)
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
| `:cancel_token` | `CancelToken.t()` | No | Accepted; integration in Phase 2 |
| `:context_policy` | `ContextPolicy.t()` | No | Accepted; integration in Phase 2 |
| `:telemetry_metadata` | `map()` | No | Accepted; integration in Phase 2 |

## Cancellation

`CancelToken` provides boundary-cooperative cancellation using lock-free atomics:

```elixir
token = Agora.CancelToken.new()

# Start orchestration in another process
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

Cancellation is checked at orchestration loop boundaries — it does not interrupt in-flight provider calls or tool executions. This matches the cooperative model used by `Agora.Middleware.Timeout`.

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
