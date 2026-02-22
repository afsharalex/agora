# Orchestration

> **Recommended entry point:** For the unified `run_mode/3` API covering all orchestrator modes
> (`:single`, `:round_robin`, `:group_chat`, `:supervisor`, `:plan`, `:handoff`),
> see [Execution Modes](execution-modes.md). This guide covers advanced topics: custom
> orchestrator implementation, termination conditions, and direct Runner lifecycle management.

## Built-in Orchestrators

| Orchestrator | Mode Atom | Description |
|-------------|-----------|-------------|
| `Agora.Orchestrator.Single` | `:single` | Runs one agent to completion |
| `Agora.Orchestrator.RoundRobin` | `:round_robin` | Cycles through agents, each receives previous response |
| `Agora.Orchestrator.Supervisor` | `:supervisor` | One agent delegates to workers via `DELEGATE:name:message` |
| `Agora.Orchestrator.ChatRoom` | `:group_chat` | Shared transcript -- all agents see the full conversation |
| `Agora.Orchestrator.Plan` | `:plan` | Autonomous plan-execute-review cycle |
| `Agora.Orchestrator.Handoff` | `:handoff` | Decentralized baton-passing between agents |

`Agora.Orchestrator.GroupChat` is an alias for `ChatRoom`.

## RoundRobin Example

Using the recommended `run_mode/3` API:

```elixir
alias Agora.{AgentConfig, Orchestrator.TerminationCondition}

agents = %{
  researcher: AgentConfig.new!(
    provider: :anthropic, model: "claude-sonnet-4-20250514",
    instructions: "You are a research assistant."
  ),
  writer: AgentConfig.new!(
    provider: :anthropic, model: "claude-sonnet-4-20250514",
    instructions: "You are a technical writer."
  )
}

{:ok, response} = Agora.run_mode(:round_robin, "Research and write about BEAM concurrency",
  agents: agents,
  termination: TerminationCondition.keyword_match(["FINAL ANSWER"])
)
```

The Runner API below is available for advanced use cases requiring direct lifecycle management:

```elixir
alias Agora.Orchestrator.Runner

{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.RoundRobin,
  agents: agents,
  termination: TerminationCondition.keyword_match(["FINAL ANSWER"])
)

{:ok, response} = Runner.run(runner, "Research and write about BEAM concurrency")
Agora.stop_runner(runner)
```

## Supervisor Delegation

One supervisor agent delegates tasks to named workers using a `DELEGATE:name:message` protocol:

```elixir
agents = %{
  manager: AgentConfig.new!(
    provider: :anthropic, model: "claude-sonnet-4-20250514",
    instructions: "You are a manager. Delegate tasks using DELEGATE:worker_name:task message."
  ),
  analyst: AgentConfig.new!(
    provider: :anthropic, model: "claude-sonnet-4-20250514",
    instructions: "You are a data analyst."
  ),
  writer: AgentConfig.new!(
    provider: :anthropic, model: "claude-sonnet-4-20250514",
    instructions: "You are a technical writer."
  )
}

{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.Supervisor,
  agents: agents,
  orchestrator_opts: [supervisor_agent: :manager]
)

{:ok, response} = Runner.run(runner, "Analyze and document this data")
```

## ChatRoom

All agents share a full conversation transcript:

```elixir
{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.ChatRoom,
  agents: agents,
  termination: TerminationCondition.max_turns(6)
)
```

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

# Custom orchestrators use the Runner API directly (run_mode/3 only supports built-in modes):
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

## Safety

The Runner enforces a hard `max_turns` limit (default 100) separate from termination conditions, preventing runaway orchestration loops.
