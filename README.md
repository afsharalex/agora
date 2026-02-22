<p align="center">
  <img src="assets/logo.png" alt="Agora" width="400">
</p>

<p align="center">
  <strong>Multi-agent runtime framework for Elixir</strong>
</p>

<p align="center">
  <a href="#installation">Installation</a> |
  <a href="#quick-start">Quick Start</a> |
  <a href="#coordination-patterns">Patterns</a> |
  <a href="#streaming">Streaming</a> |
  <a href="#middleware">Middleware</a> |
  <a href="#workflows">Workflows</a> |
  <a href="#observability">Observability</a> |
  <a href="docs/internal/Design-v0.md">Design Doc</a>
</p>

---

Agora is a framework for building collaborative AI agents on the BEAM. Define agents, compose them into teams, and let them coordinate through structured messaging and orchestration patterns.

## Features

- **Agent-first** -- Define agents with `Agora.agent/3`, compose them with seven built-in coordination patterns
- **Provider-agnostic** -- Unified interface across Anthropic, OpenAI, and custom LLM providers
- **BEAM-native** -- Agents as supervised processes, tool execution via `Task.Supervisor`, per-run supervision trees
- **Structured errors** -- Typed `{:ok, result} | {:error, %Error{}}` tuples throughout (no exceptions for control flow)
- **Agent-as-tool** -- Wrap any agent as a tool for hierarchical composition with depth-guarded recursion
- **Middleware system** -- Composable interceptors for logging, token budgets, timeouts, approval gates
- **Memory backends** -- Bound conversation growth with ring buffers or persist history to disk
- **Streaming** -- Real-time token streaming with `stream/2`, composable `Enumerable` streams
- **Observability** -- Telemetry events for providers, tools, middleware, agents, and workflows

## Installation

Add `agora` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agora, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Start

### Define and run a single agent

```elixir
assistant = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant."
)

{:ok, response} = Agora.run(assistant, "What is Elixir?")
IO.puts(response.content)
```

### Try without an API key

```elixir
assistant = Agora.agent(:echo, "echo")

{:ok, response} = Agora.run(assistant, "Hello!")
IO.puts(response.content)
# => "Echo: Hello!"
```

### Compose a team

```elixir
researcher = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  name: "researcher",
  instructions: "You are a research analyst."
)

writer = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  name: "writer",
  instructions: "You are a technical writer."
)

# Sequential pipeline: researcher → writer
{:ok, results} = Agora.sequential("Write about the BEAM VM", [
  researcher: researcher,
  writer: writer
])
```

### Agent-as-tool

```elixir
research_tool = Agora.agent_tool(researcher,
  name: "research_agent",
  description: "Delegates research tasks to a specialist."
)

supervisor = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "Use research_agent when you need research.",
  tools: [research_tool]
)

{:ok, response} = Agora.run(supervisor, "Research and summarize BEAM concurrency")
```

## Coordination Patterns

| Function | Pattern | Use When |
|----------|---------|----------|
| `sequential/3` | A → B → C | Pipeline processing |
| `parallel/3` | A \| B \| C | Independent subtasks |
| `round_robin/3` | A → B → A → B | Iterative refinement |
| `group_chat/3` | Shared transcript | Collaborative discussion |
| `supervisor/4` | Delegation | Manager + workers |
| `plan/4` | Planned execution | Complex multi-step tasks |
| `handoff/3` | Baton passing | Decentralized routing |
| `agent_tool/2` | Agent-as-tool | Hierarchical nesting |

### Autonomous coordination

```elixir
alias Agora.Orchestrator.TerminationCondition

{:ok, response} = Agora.round_robin("Discuss BEAM concurrency", [
  researcher: researcher,
  writer: writer
], termination: TerminationCondition.max_turns(4))
```

### Manager-worker delegation

```elixir
manager = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "Delegate research to analyst, writing to writer using DELEGATE:name:task."
)

{:ok, response} = Agora.supervisor("Analyze and document this data",
  {:manager, manager},
  [analyst: analyst, writer: writer]
)
```

See the [Composition](guides/composition.md) guide for the full pattern catalog.

## Providers

| Provider | Module | Status |
|----------|--------|--------|
| Anthropic | `Agora.Provider.Anthropic` | Available |
| OpenAI | `Agora.Provider.OpenAI` | Available |
| Echo (test) | `Agora.Provider.Echo` | Available |

```elixir
# Per-agent provider options
agent = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  provider_opts: [
    api_key: "sk-ant-different-key",
    timeout: 60_000,
    max_tokens: 8192
  ]
)
```

## Streaming

Stream tokens as they're generated:

```elixir
agent = Agora.agent(:anthropic, "claude-sonnet-4-20250514")

{:ok, stream} = Agora.stream(agent, "Tell me a story")

stream
|> Stream.filter(&(&1.type == :text_delta))
|> Enum.each(fn event -> IO.write(event.data.text) end)
```

## Middleware

Composable interceptors for the agent reasoning loop:

```elixir
agent = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  middleware: [
    Agora.Middleware.Logger,
    Agora.Middleware.MaxTokens.new(max_tokens: 4000),
    Agora.Middleware.Timeout.new(timeout_ms: 30_000)
  ]
)
```

## Memory

```elixir
agent = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  memory: {Agora.Memory.Buffer, max_messages: 100}
)

{:ok, pid} = Agora.start_agent(agent)
# Conversation bounded to last 100 messages
```

## Workflows

For deterministic DAG pipelines with retries, checkpoints, and parallel fan-out:

```elixir
alias Agora.Workflow.Builder

workflow =
  Builder.new(step_defaults: [retry: 1])
  |> Builder.chain([
    {:fetch, fn _r -> {:ok, fetch_data()} end},
    {:transform, fn r -> {:ok, transform(elem(r[:fetch], 1))} end},
    {:save, fn r -> {:ok, save(elem(r[:transform], 1))} end}
  ])
  |> Builder.build!()

{:ok, results} = Agora.run_workflow(workflow)
```

See the [Workflows](guides/workflows.md) guide for the full Builder API, DSLs, and agent-powered steps.

## Observability

Agora emits telemetry events at key instrumentation points:

| Event prefix | Emitted by |
|---|---|
| `[:agora, :agent, :run]` | `Agora.Agent` |
| `[:agora, :provider, :call]` | `Agora.Provider` |
| `[:agora, :tool, :call]` | `Agora.ToolBroker` |
| `[:agora, :middleware, :call]` | `Agora.Middleware.Chain` |
| `[:agora, :orchestrator, :run]` | `Agora.Orchestrator.Runner` |
| `[:agora, :workflow, :run]` | `Agora.Workflow.Executor` |

## Development

```bash
mix deps.get                    # Install dependencies
mix test                        # Run all tests
mix test --only describe:"chat" # Run tests matching describe
mix format                      # Auto-format
mix dialyzer                    # Static type analysis
```

## License

[MIT](LICENSE) -- Copyright (c) 2026 Alex Afshar
