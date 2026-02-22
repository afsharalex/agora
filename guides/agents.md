# Agents

Agents are the core building block in Agora. Each agent wraps an LLM provider with instructions, tools, middleware, and memory to create a specialized worker.

## Defining Agents

Use `Agora.agent/3` as the primary way to define agents:

```elixir
researcher = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  name: "researcher",
  instructions: "You are a research analyst. Find and synthesize information.",
  tools: [MyApp.SearchTool]
)
```

This returns an `%AgentConfig{}` struct — a data description of the agent, not a running process.

### Configuration Options

| Option | Type | Description |
|--------|------|-------------|
| `:name` | `String.t()` | Human-readable name (used in telemetry and orchestration) |
| `:instructions` | `String.t()` | System prompt sent with every request |
| `:tools` | `[module()]` | Tool modules the agent can call |
| `:middleware` | `[module() \| fun]` | Interceptors for the reasoning loop |
| `:memory` | `{module, keyword()}` | Persistent message storage backend |
| `:max_iterations` | `pos_integer()` | Safety limit on reasoning loop iterations (default 10) |
| `:provider_opts` | `keyword()` | Provider-specific options (API keys, timeouts, etc.) |

## Running a Single Agent

### One-shot (ephemeral)

`Agora.run/2` creates a temporary agent process, runs the input, and cleans up:

```elixir
{:ok, response} = Agora.run(researcher, "What is the BEAM virtual machine?")
IO.puts(response.content)
```

### One-shot streaming

`Agora.stream/2` streams tokens as they're generated:

```elixir
{:ok, stream} = Agora.stream(researcher, "Tell me about OTP")

stream
|> Stream.filter(&(&1.type == :text_delta))
|> Enum.each(fn event -> IO.write(event.data.text) end)
```

### Long-lived (persistent)

For multi-turn conversations, start a supervised agent process:

```elixir
{:ok, pid} = Agora.start_agent(researcher)

{:ok, r1} = Agora.Agent.run(pid, "My name is Alice.")
{:ok, r2} = Agora.Agent.run(pid, "What is my name?")
# The agent remembers the conversation

Agora.stop_agent(pid)
```

## Composing Agents

The real power comes from composing multiple agents. See the [Composition](composition.md) guide for the full pattern catalog.

### Quick example: sequential pipeline

```elixir
researcher = Agora.agent(:echo, "echo",
  name: "researcher", instructions: "You research topics."
)
writer = Agora.agent(:echo, "echo",
  name: "writer", instructions: "You write articles."
)

{:ok, results} = Agora.sequential("Write about BEAM", [
  researcher: researcher,
  writer: writer
])
```

### Quick example: agent-as-tool

```elixir
research_tool = Agora.agent_tool(researcher,
  name: "research_agent",
  description: "Delegates research tasks to a specialized agent."
)

supervisor = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "Use research_agent for research tasks.",
  tools: [research_tool]
)

{:ok, response} = Agora.run(supervisor, "Research the BEAM VM")
```

## Agent Lifecycle

Agents can operate in two modes:

**Ephemeral** — Created and destroyed per-call via `Agora.run/2` or the composition functions. No state persists between calls. This is the default and recommended mode for most use cases.

**Persistent** — Started via `Agora.start_agent/2`, maintains conversation history across multiple `Agent.run/2` calls. Use when you need multi-turn conversations or stateful agents.

### Memory

Memory backends let persistent agents bound conversation growth and survive restarts:

```elixir
agent = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  memory: {Agora.Memory.Buffer, max_messages: 100}
)
```

| Backend | Description |
|---------|-------------|
| `Agora.Memory.Buffer` | In-memory ring buffer, keeps last N messages |
| `Agora.Memory.File` | JSON file persistence with atomic writes |

### Middleware

Middleware intercepts the agent reasoning loop at defined hook points:

```elixir
agent = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  middleware: [
    Agora.Middleware.Logger,
    Agora.Middleware.Timeout.new(timeout_ms: 30_000),
    Agora.Middleware.MaxTokens.new(max_tokens: 4000)
  ]
)
```

See the [Middleware](middleware.md) guide for details.

## See Also

- [Composition](composition.md) -- All coordination patterns
- [Providers](providers.md) -- Configure Anthropic, OpenAI, or custom providers
- [Tools](tools.md) -- Create tools for your agents
- [Middleware](middleware.md) -- Interceptors for logging, timeouts, budgets
