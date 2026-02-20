# Orchestration

How to coordinate multiple agents using orchestrators and termination conditions.

## Overview

Orchestrators control **which** agent runs and **what input** it receives, without modifying how agents work internally. The `Agora.Orchestrator.Runner` GenServer drives the orchestration loop.

## Built-in Orchestrators

| Orchestrator | Description |
|-------------|-------------|
| `Agora.Orchestrator.Single` | Runs one agent to completion |
| `Agora.Orchestrator.RoundRobin` | Cycles through agents, each receives previous response |
| `Agora.Orchestrator.Supervisor` | One agent delegates to workers via `DELEGATE:name:message` |
| `Agora.Orchestrator.ChatRoom` | Shared transcript -- all agents see the full conversation |

## RoundRobin Example

Agents take turns, each receiving the previous agent's response:

```elixir
alias Agora.{AgentConfig, Orchestrator.Runner, Orchestrator.TerminationCondition}

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

{:ok, runner} = Runner.start_link(
  orchestrator: Agora.Orchestrator.RoundRobin,
  agents: agents,
  termination: TerminationCondition.keyword_match(["FINAL ANSWER"])
)

{:ok, response} = Runner.run(runner, "Research and write about BEAM concurrency")
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

## Convenience Functions

```elixir
# Start a runner under the built-in supervisor
{:ok, runner} = Agora.start_runner(
  orchestrator: Agora.Orchestrator.RoundRobin,
  agents: agents,
  termination: TerminationCondition.max_turns(5)
)

# Run and stop
{:ok, response} = Agora.Orchestrator.Runner.run(runner, "Hello")
Agora.stop_runner(runner)
```

## Implement a Custom Orchestrator

```elixir
defmodule MyApp.Orchestrator.Priority do
  @behaviour Agora.Orchestrator

  @impl true
  def init(config) do
    {:ok, %{agents: config.agents, priority_order: config.opts[:priority]}}
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
```

The orchestrator behaviour has three callbacks:
- `init/1` -- Initialize state from config
- `next/2` -- Pick next agent and input message
- `handle_result/3` -- Process agent result, decide to continue or stop

## Safety

The Runner enforces a hard `max_turns` limit (default 100) separate from termination conditions, preventing runaway orchestration loops.
