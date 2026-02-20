<p align="center">
  <img src="assets/logo.png" alt="Agora" width="400">
</p>

<p align="center">
  <strong>Multi-agent runtime framework for Elixir</strong>
</p>

<p align="center">
  <a href="#installation">Installation</a> |
  <a href="#quick-start">Quick Start</a> |
  <a href="#providers">Providers</a> |
  <a href="#streaming">Streaming</a> |
  <a href="#middleware">Middleware</a> |
  <a href="#memory">Memory</a> |
  <a href="#orchestration">Orchestration</a> |
  <a href="#workflows">Workflows</a> |
  <a href="#observability">Observability</a> |
  <a href="#architecture">Architecture</a> |
  <a href="docs/Design-v0.md">Design Doc</a> |
  <a href="TODO.md">Roadmap</a>
</p>

---

Agora is a framework for building collaborative AI agents on the BEAM. Agents are supervised processes that coordinate through structured messaging and orchestration strategies, leveraging OTP for fault tolerance and concurrency.

## Features

- **Provider-agnostic** -- Unified interface across Anthropic, OpenAI, and custom LLM providers
- **Declarative agent config** -- Define agents with provider, model, instructions, tools, and middleware
- **Structured errors** -- Typed `{:ok, result} | {:error, %Error{}}` tuples throughout (no exceptions for control flow)
- **BEAM-native** -- Agents as supervised processes, tool execution via `Task.Supervisor`, per-run supervision trees
- **Middleware system** -- Composable interceptors for logging, token budgets, timeouts, approval gates, and custom behavior
- **Memory backends** -- Bound conversation growth with ring buffers or persist history to disk across restarts
- **Orchestration patterns** -- Single, round-robin, supervisor delegation, and chat-room multi-agent coordination
- **Streaming** -- Real-time token streaming with `stream_run/2`, composable `Enumerable` stream, multi-turn tool execution
- **Observability** -- Telemetry events for providers, tools, middleware, and agents; Registry-backed EventBus for pub/sub

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

### Configure API keys

Set environment variables for your providers:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
```

Or configure in `config/runtime.exs`:

```elixir
config :agora,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY")
```

### One-shot agent

The simplest way to use an agent — creates a temporary process, runs, and cleans up:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant."
)

{:ok, response} = Agora.run(config, "Hello!")
IO.puts(response.content)
# => "Hello! How can I help you today?"
```

### One-shot streaming

Stream tokens as they're generated:

```elixir
{:ok, stream} = Agora.stream(config, "Tell me a story")

stream
|> Stream.filter(&(&1.type == :text_delta))
|> Enum.each(fn event -> IO.write(event.data.text) end)
```

### Long-lived agent

For multi-turn conversations, start a supervised agent process:

```elixir
alias Agora.{AgentConfig, Agent}

config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant."
)

{:ok, pid} = Agent.start_link(config: config)
{:ok, response} = Agent.run(pid, "Hello!")

IO.puts(response.content)
# => "Hello! How can I help you today?"
```

### Agent with tools

```elixir
alias Agora.{AgentConfig, Agent}
alias Agora.Tool.Calculator

config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "Use the calculator tool when asked math questions.",
  tools: [Calculator]
)

{:ok, pid} = Agent.start_link(config: config)
{:ok, response} = Agent.run(pid, "What is 42 * 17?")
# Agent calls Calculator tool, feeds result back to LLM, returns final answer
```

### Agent with middleware

```elixir
alias Agora.{AgentConfig, Agent}
alias Agora.Middleware.{Logger, MaxTokens, Timeout}

config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant.",
  middleware: [
    Logger,                              # logs each hook point
    MaxTokens.new(max_tokens: 4000),     # halt if token estimate exceeds budget
    Timeout.new(timeout_ms: 30_000)      # cooperative wall-clock timeout
  ]
)

{:ok, pid} = Agent.start_link(config: config)
{:ok, response} = Agent.run(pid, "Hello!")
```

### Supervised agents

```elixir
config = AgentConfig.new!(provider: :anthropic, model: "claude-sonnet-4-20250514")

# Start under the built-in DynamicSupervisor
{:ok, pid} = Agora.start_agent(config)
{:ok, response} = Agent.run(pid, "Hello!")

# Stop when done
Agora.stop_agent(pid)
```

### Direct provider calls

For one-off calls without the agent loop:

```elixir
alias Agora.{AgentConfig, Message, Provider}

config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514"
)

{:ok, response} = Provider.chat(:anthropic, [Message.user("Hello!")], config)
```

### Use OpenAI instead

```elixir
config = AgentConfig.new!(
  provider: :openai,
  model: "gpt-4o",
  instructions: "You are a helpful assistant."
)

{:ok, pid} = Agent.start_link(config: config)
{:ok, response} = Agent.run(pid, "Hello!")
```

### Per-agent provider options

```elixir
config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  provider_opts: [
    api_key: "sk-ant-different-key",
    base_url: "https://my-proxy.example.com",
    timeout: 60_000,
    max_tokens: 8192
  ]
)
```

## Providers

| Provider | Module | Status |
|----------|--------|--------|
| Anthropic | `Agora.Provider.Anthropic` | Available |
| OpenAI | `Agora.Provider.OpenAI` | Available |
| Echo (test) | `Agora.Provider.Echo` | Available |

All providers implement the `Agora.Provider` behaviour:

```elixir
@callback chat(messages :: [Message.t()], config :: AgentConfig.t()) ::
  {:ok, Message.t()} | {:error, Error.t()}

# Optional -- enables stream_run/2
@callback stream_chat(messages :: [Message.t()], config :: AgentConfig.t()) ::
  {:ok, %{pid: pid(), ref: reference()}} | {:error, Error.t()}
```

### Provider-specific behavior

- **Anthropic** -- System messages extracted to top-level `system` parameter. Adjacent same-role messages merged automatically. Tool results sent as `user` role with `tool_result` content blocks.
- **OpenAI** -- System messages stay inline. Tool arguments encoded/decoded as JSON strings. One Agora tool message with N results expands to N separate OpenAI `tool` messages.
- **Echo** -- Six configurable modes for testing (`:echo`, `:fixed`, `:sequence`, `:error`, `:tool_call`, `:function`). No HTTP calls. Streaming mode adds `:stream` with explicit events, functions, and delays.

## Streaming

Stream tokens from the LLM as they are generated, instead of waiting for the complete response.

### Basic streaming

```elixir
{:ok, pid} = Agent.start_link(config: config)
{:ok, stream} = Agent.stream_run(pid, "Tell me a story")

# Print tokens as they arrive
stream
|> Stream.filter(&(&1.type == :text_delta))
|> Enum.each(fn event -> IO.write(event.data.text) end)
```

### Collect all events

```elixir
{:ok, stream} = Agent.stream_run(pid, "Hello")
events = Enum.to_list(stream)

# Events include :text_delta, :message_complete, :done, etc.
```

### Multi-turn streaming with tools

When the LLM returns tool calls during streaming, the agent automatically executes them and streams the follow-up response. Tool results are emitted as `:tool_result` events between turns.

```elixir
config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  tools: [Calculator]
)

{:ok, pid} = Agent.start_link(config: config)
{:ok, stream} = Agent.stream_run(pid, "What is 42 * 17?")

Enum.each(stream, fn event ->
  case event.type do
    :text_delta -> IO.write(event.data.text)
    :tool_result -> IO.puts("\n[Tool: #{event.data.name} -> #{event.data.content}]")
    :done -> IO.puts("\n--- Done ---")
    _ -> :ok
  end
end)
```

### Stream event types

| Type | Data | Description |
|------|------|-------------|
| `:text_delta` | `%{text: "chunk"}` | Incremental text token |
| `:tool_call_start` | `%{id: _, name: _, index: _}` | Tool call begins |
| `:tool_call_delta` | `%{id: _, arguments_fragment: _}` | Partial JSON arguments |
| `:tool_result` | `%ToolResult{}` | Tool execution result |
| `:message_complete` | `%Message{}` | Accumulated complete message |
| `:done` | `%{}` | Stream finished |
| `:error` | `%Error{}` | Error occurred |

### Middleware with streaming

The `:on_stream_event` hook lets middleware intercept, transform, or suppress individual stream events:

```elixir
upcase_mw = fn ctx, next ->
  if ctx.hook == :on_stream_event && ctx.stream_event.type == :text_delta do
    event = ctx.stream_event
    upper_text = String.upcase(event.data.text)
    new_event = %{event | data: %{text: upper_text}}
    next.(%{ctx | stream_event: new_event})
  else
    next.(ctx)
  end
end

config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  middleware: [upcase_mw]
)
```

## Middleware

Middleware are composable interceptors that hook into the agent reasoning loop. They can be modules implementing `Agora.Middleware` or 2-arity closures returned by factory functions.

### Hook points

| Hook | When | Can modify |
|------|------|------------|
| `:before_provider_call` | Before LLM call | messages, config |
| `:after_provider_call` | After LLM response | response, tool_calls (controls execution) |
| `:before_tool_call` | Before tool execution | tool_calls (filter/approve) |
| `:after_tool_call` | After tool execution | tool_results |
| `:on_stream_event` | Per streaming event | stream_event (transform/suppress) |

### Built-in middleware

| Module | Description |
|--------|-------------|
| `Agora.Middleware.Logger` | Logs events at each hook point via `Logger.debug` |
| `Agora.Middleware.MaxTokens` | Halts if estimated token count exceeds a budget |
| `Agora.Middleware.Timeout` | Cooperative wall-clock timeout across iterations |
| `Agora.Middleware.ToolApproval` | Gates tool execution with an approval function |

### Custom middleware

```elixir
# As a module
defmodule MyMiddleware do
  @behaviour Agora.Middleware

  def call(%{hook: :before_provider_call} = ctx, next) do
    # modify ctx, then continue
    next.(ctx)
  end

  def call(ctx, next), do: next.(ctx)
end

# As a closure
my_mw = fn ctx, next ->
  if ctx.hook == :before_tool_call do
    # inspect or filter tool_calls
    next.(ctx)
  else
    next.(ctx)
  end
end
```

## Memory

Memory backends let agents bound conversation growth and persist history across restarts. Memory is configured via a `{module, opts}` tuple on the agent config.

### In-memory ring buffer

```elixir
config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant.",
  memory: {Agora.Memory.Buffer, max_messages: 100}
)

{:ok, pid} = Agent.start_link(config: config)
# After each run, only the last 100 non-system messages are kept
```

### File persistence

```elixir
config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant.",
  memory: {Agora.Memory.File, path: "/tmp/agent_history.json"}
)

{:ok, pid} = Agent.start_link(config: config)
{:ok, _} = Agent.run(pid, "Remember this conversation")
GenServer.stop(pid)

# Restart -- history is loaded from disk
{:ok, pid2} = Agent.start_link(config: config)
# pid2 sees the full conversation from the previous session
```

### Clear memory

```elixir
Agent.clear_memory(pid)  # removes all persisted messages
```

### Built-in backends

| Backend | Description |
|---------|-------------|
| `Agora.Memory.Buffer` | In-memory ring buffer, keeps last `:max_messages` |
| `Agora.Memory.File` | JSON file persistence with atomic writes |

## Orchestration

Orchestrators coordinate multiple agents without modifying how agents work internally.

### Multi-agent coordination

```elixir
alias Agora.{AgentConfig, Orchestrator.Runner, Orchestrator.TerminationCondition}

# Define agent configs
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

# Round-robin: agents take turns, each receiving the previous response
{:ok, pid} = Runner.start_link(
  orchestrator: Agora.Orchestrator.RoundRobin,
  agents: agents,
  termination: TerminationCondition.keyword_match(["FINAL ANSWER"])
)

{:ok, response} = Runner.run(pid, "Research and write about BEAM concurrency")
```

### Built-in orchestrators

| Orchestrator | Description |
|-------------|-------------|
| `Agora.Orchestrator.Single` | Runs one agent to completion (baseline) |
| `Agora.Orchestrator.RoundRobin` | Cycles through agents, each receives previous response |
| `Agora.Orchestrator.Supervisor` | One agent delegates to workers via `DELEGATE:name:message` |
| `Agora.Orchestrator.ChatRoom` | Shared transcript — all agents see the full conversation |

### Termination conditions

```elixir
alias Agora.Orchestrator.TerminationCondition

# Composable conditions
condition = TerminationCondition.any_of([
  TerminationCondition.max_turns(10),
  TerminationCondition.keyword_match(["DONE", "FINAL"])
])
```

## Workflows

Workflows define deterministic DAG-based pipelines where execution order is predetermined. Unlike orchestrators (LLM-driven routing), workflows follow predefined step dependencies with parallel fan-out, conditional branching, retry, and checkpoint-based resumability.

### Build and run a workflow

```elixir
alias Agora.Workflow.Builder

workflow =
  Builder.new()
  |> Builder.step(:fetch, fn _r -> {:ok, fetch_data()} end)
  |> Builder.step(:transform, fn r -> {:ok, transform(elem(r[:fetch], 1))} end)
  |> Builder.step(:save, fn r -> {:ok, save(elem(r[:transform], 1))} end)
  |> Builder.sequence([:fetch, :transform, :save])
  |> Builder.build!()

{:ok, results} = Agora.run_workflow(workflow, input: "source")
```

### Parallel fan-out/fan-in

```elixir
workflow =
  Builder.new()
  |> Builder.step(:source, fn _r -> {:ok, data} end)
  |> Builder.step(:analyze, fn r -> {:ok, analyze(elem(r[:source], 1))} end)
  |> Builder.step(:summarize, fn r -> {:ok, summarize(elem(r[:source], 1))} end)
  |> Builder.step(:combine, fn r ->
    {:ok, merge(elem(r[:analyze], 1), elem(r[:summarize], 1))}
  end)
  |> Builder.parallel([:analyze, :summarize], from: :source, to: :combine)
  |> Builder.build!()
```

### Conditional branching

```elixir
workflow =
  Builder.new()
  |> Builder.step(:check, fn r -> {:ok, r[:input]} end)
  |> Builder.step(:path_a, fn _r -> {:ok, "took path A"} end)
  |> Builder.step(:path_b, fn _r -> {:ok, "took path B"} end)
  |> Builder.edge(:check, :path_a, condition: fn r -> elem(r[:check], 1) == "go_a" end)
  |> Builder.edge(:check, :path_b, condition: fn r -> elem(r[:check], 1) == "go_b" end)
  |> Builder.build!()
```

### Agent-powered steps

Steps can use `AgentConfig` as the handler to run an LLM agent within the workflow:

```elixir
config = AgentConfig.new!(provider: :anthropic, model: "claude-sonnet-4-20250514")

workflow =
  Builder.new()
  |> Builder.step(:data, fn _r -> {:ok, fetch_data()} end)
  |> Builder.step(:agent, config, input_mapper: fn r -> "Analyze: #{elem(r[:data], 1)}" end)
  |> Builder.sequence([:data, :agent])
  |> Builder.build!()
```

### Checkpoint persistence

Resume workflows from where they left off using checkpoint stores:

```elixir
{:ok, results} = Agora.run_workflow(workflow,
  checkpoint_store: {Agora.Workflow.CheckpointStore.File, path: "/tmp/workflow.json"}
)
```

### Workflow features

| Feature | Description |
|---------|-------------|
| Retry | Per-step retry count with crash recovery (`retry: 3`) |
| Timeout | Per-step deadline-based timeout (`timeout: 30_000`) |
| Failure modes | `:abort` (default) fails fast; `:skip` continues past failures |
| Auto-edges | Declare `inputs: [:a, :b]` on a step to auto-generate dependency edges |
| Determinism | Steps within each topological level are sorted before execution |

## Observability

Agora emits telemetry events at key instrumentation points via the `:telemetry` library. Attach handlers to observe agent behavior without modifying agent code.

### Telemetry events

| Event prefix | Suffix events | Emitted by |
|---|---|---|
| `[:agora, :agent, :run]` | `:start`, `:stop`, `:exception` | `Agora.Agent` |
| `[:agora, :agent, :loop_iteration]` | `:start`, `:stop` | `Agora.Agent` |
| `[:agora, :provider, :call]` | `:start`, `:stop`, `:exception` | `Agora.Provider` |
| `[:agora, :tool, :call]` | `:start`, `:stop`, `:exception` | `Agora.ToolBroker` |
| `[:agora, :middleware, :call]` | `:start`, `:stop` | `Agora.Middleware.Chain` |
| `[:agora, :orchestrator, :run]` | `:start`, `:stop` | `Agora.Orchestrator.Runner` |
| `[:agora, :orchestrator, :step]` | `:start`, `:stop` | `Agora.Orchestrator.Runner` |
| `[:agora, :workflow, :run]` | `:start`, `:stop`, `:exception` | `Agora.Workflow.Executor` |
| `[:agora, :workflow, :step]` | `:start`, `:stop`, `:exception` | `Agora.Workflow.Executor` |
| `[:agora, :provider, :stream]` | `:start`, `:stop` | `Agora.Provider` |
| `[:agora, :agent, :stream_run]` | `:start`, `:stop` | `Agora.Agent` |

See `Agora.Telemetry` moduledoc for full measurement and metadata details per event.

### EventBus

A lightweight Registry-backed pub/sub for internal component messaging, UI integration, and debugging:

```elixir
Agora.EventBus.subscribe(:agent_events)
Agora.EventBus.broadcast(:agent_events, %{status: :completed})

receive do
  {Agora.EventBus, :agent_events, message} -> IO.inspect(message)
end
```

The EventBus is intentionally decoupled from telemetry -- users can bridge the two if desired.

## Architecture

```
User → Agent.run/2 → reasoning loop:
  [before_provider_call middleware]
  Provider.chat/3 → response
  [after_provider_call middleware]
    ├─ tool_calls?
    │   [before_tool_call middleware]
    │   ToolBroker.execute/2 → tool_results
    │   [after_tool_call middleware]
    │   → loop
    └─ text only? → return {:ok, Message.t()}

User → Agent.stream_run/2 → streaming loop:
  Provider.stream_chat/3 → event stream
    [on_stream_event middleware per event]
    ├─ tool_calls in message?
    │   execute tools → emit :tool_result events
    │   → re-stream (new provider call)
    └─ text only? → emit :done, return Agora.Stream.t()
```

### Core modules

| Module | Purpose |
|--------|---------|
| `Agora.Agent` | GenServer with reasoning loop (provider call → tool execution → repeat) |
| `Agora.Agent.Supervisor` | DynamicSupervisor for agent lifecycle management |
| `Agora.AgentConfig` | NimbleOptions-validated configuration |
| `Agora.Provider` | Behaviour + resolution (`resolve/1` maps atoms to modules) |
| `Agora.Message` | Universal message struct (role, content, tool_calls, tool_results, metadata) |
| `Agora.Error` | Typed errors: `:provider_error`, `:auth_error`, `:rate_limit`, `:timeout`, etc. |
| `Agora.Tool` | Behaviour for defining tools + `FunctionTool` for inline definitions |
| `Agora.ToolBroker` | Supervised parallel tool execution with timeout enforcement |
| `Agora.Memory` | Behaviour for memory backends (Buffer, File) with dispatch via `{module, state}` |
| `Agora.Middleware` | Behaviour for composable interceptors at 4 hook points |
| `Agora.Middleware.Chain` | Plug-style chain executor with error safety |
| `Agora.Tool.Schema` | JSON Schema helpers for tool parameter validation |
| `Agora.Orchestrator` | Behaviour for multi-agent orchestration strategies |
| `Agora.Orchestrator.Runner` | GenServer driving orchestration loops with crash protection |
| `Agora.Orchestrator.TerminationCondition` | Composable conditions (closures) for stopping orchestration |
| `Agora.Telemetry` | Telemetry helpers (`span/3`, `emit/3`) and canonical event documentation |
| `Agora.EventBus` | Registry-backed pub/sub for internal component messaging |
| `Agora.Workflow` | DAG-based workflow struct (steps, edges, metadata) |
| `Agora.Workflow.Builder` | DSL for constructing workflows (step, edge, sequence, parallel) |
| `Agora.Workflow.Executor` | Stateless DAG executor with parallel fan-out, retry, checkpoints |
| `Agora.Workflow.CheckpointStore` | Behaviour for checkpoint persistence (Memory, File backends) |
| `Agora.StreamEvent` | Typed streaming event struct (text_delta, tool_call_start/delta, tool_result, message_complete, done, error) |
| `Agora.Stream` | Enumerable wrapper for consuming streaming events with ownership enforcement |
| `Agora.Provider.SSE` | Shared SSE line parser with partial-data buffering |
| `Agora.Provider.StreamAccumulator` | Accumulates streaming deltas into a complete Message |
| `Agora.Config` | Application-level config helpers with provider-namespaced keys |

### Config resolution order

Provider options follow a two-tier lookup:

1. `provider_opts` on the `AgentConfig` (per-agent)
2. Application config with provider-namespaced keys (e.g., `:anthropic_base_url`, `:openai_timeout`)

### HTTP testing

Providers accept `req_options` in `provider_opts` for test injection via `Req.Test`:

```elixir
config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  provider_opts: [
    api_key: "test-key",
    req_options: [plug: {Req.Test, MyTest}]
  ]
)
```

## Roadmap

Agora follows a 10-phase implementation plan. See [TODO.md](TODO.md) for full details.

| Phase | Name | Status |
|-------|------|--------|
| 0 | Project Foundation | Complete |
| 1 | Provider Abstraction Layer | Complete |
| 2 | Tool System | Complete |
| 3 | Agent Runtime | Complete |
| 4 | Middleware System | Complete |
| 5 | Orchestration | Complete |
| 6 | Memory System | Complete |
| 7 | Observability | Complete |
| 8 | Workflow Engine | Complete |
| 9 | Streaming Support | Complete |
| 10 | Top-Level API & Release | Complete |

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
