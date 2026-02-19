# Agora — Implementation Roadmap

> Multi-agent runtime framework for Elixir leveraging the BEAM actor model.
> Reference: [`docs/Design-v0.md`](docs/Design-v0.md)

---

## Phase 0: Project Foundation

Set up dependencies, configuration, and core data structures that every subsequent phase builds on.

### Dependencies

- [ ] Add `jason ~> 1.4` — JSON encoding/decoding
- [ ] Add `req ~> 0.5` — HTTP client for provider API calls
- [ ] Add `nimble_options ~> 1.1` — declarative schema validation for configs
- [ ] Add `telemetry ~> 1.3` — event instrumentation and observability
- [ ] Add `ex_doc` and `dialyxir` as dev-only deps
- [ ] Run `mix deps.get` and verify compilation

### Core Structs

- [ ] `Agora.Message` — role, content, tool_calls, tool_results, metadata, timestamps
- [ ] `Agora.ToolCall` — id, name, arguments (decoded map), status
- [ ] `Agora.ToolResult` — tool_call_id, name, content, is_error flag
- [ ] `Agora.AgentConfig` — provider, model, instructions, tools, memory, middleware, max_iterations, name
  - [ ] Validate with NimbleOptions schema
- [ ] `Agora.Error` — structured error type (provider_error, tool_error, validation_error, timeout, etc.)

### Configuration

- [ ] `Agora.Config` module — application-level config helpers (provider API keys, defaults)
- [ ] Support runtime config via `config/runtime.exs` pattern

---

## Phase 1: Provider Abstraction Layer

Unified LLM interface so agents are provider-agnostic.

### Provider Behaviour

- [ ] `Agora.Provider` behaviour — `@callback chat(messages, config) :: {:ok, Message.t()} | {:error, Error.t()}`
- [ ] Define provider config options schema (api_key, base_url, headers, timeout)
- [ ] Normalize message format across providers (role mapping, tool_call format translation)

### Implementations

- [ ] `Agora.Provider.Echo` — test/dev provider that echoes input or returns canned responses
  - [ ] Unit tests for Echo provider
- [ ] `Agora.Provider.Anthropic` — Messages API integration
  - [ ] Map Agora messages to Anthropic format (system separate from messages, tool_use/tool_result content blocks)
  - [ ] Parse tool_use blocks from response into `ToolCall` structs
  - [ ] Handle API errors, rate limits, and retries
  - [ ] Unit tests with mocked HTTP responses
- [ ] `Agora.Provider.OpenAI` — Chat Completions API integration
  - [ ] Map Agora messages to OpenAI format (tool_calls in assistant messages, tool role for results)
  - [ ] Parse tool_calls from response into `ToolCall` structs
  - [ ] Handle API errors, rate limits, and retries
  - [ ] Unit tests with mocked HTTP responses

### Integration

- [ ] Provider resolution from AgentConfig (atom/module lookup)
- [ ] Integration test with Echo provider end-to-end

---

## Phase 2: Tool System

First-class tool execution with validation, permissions, and async support.

### Tool Behaviour

- [ ] `Agora.Tool` behaviour
  - [ ] `@callback name() :: String.t()`
  - [ ] `@callback description() :: String.t()`
  - [ ] `@callback schema() :: map()` — JSON Schema for parameters
  - [ ] `@callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, any()}`

### FunctionTool Adapter

- [ ] `Agora.Tool.FunctionTool` — wrap a plain `{name, description, schema, fun}` tuple as a Tool
- [ ] Macro or helper for inline tool definition without full module

### Schema Helpers

- [ ] `Agora.Tool.Schema` — helpers to build JSON Schema maps for tool parameters
  - [ ] `string/1`, `integer/1`, `boolean/1`, `array/2`, `object/2`, `enum/2`
  - [ ] `required/2` wrapper

### ToolBroker

- [ ] `Agora.ToolBroker` — centralized tool execution manager
  - [ ] Tool registry (name -> module lookup)
  - [ ] Argument validation against tool schema
  - [ ] Execute via `Task.Supervisor` for isolation and fault tolerance
  - [ ] Support parallel tool fan-out (multiple tool calls in one turn)
  - [ ] Timeout enforcement per tool call
  - [ ] Return `ToolResult` structs

### Example Tools

- [ ] `Agora.Tool.Calculator` — basic arithmetic for testing
- [ ] `Agora.Tool.DateTime` — current date/time tool
- [ ] Tests for each tool and ToolBroker execution

---

## Phase 3: Agent Runtime

The core agent process with the default reasoning/action loop.

### Agent GenServer

- [ ] `Agora.Agent` — GenServer implementing the agent loop
  - [ ] `start_link/1` accepting `AgentConfig`
  - [ ] `run/2` — send a task/message and get final response
  - [ ] Internal state: config, messages (conversation history), status (idle/running/awaiting_tool/awaiting_approval)
  - [ ] Reasoning loop:
    1. Build context (instructions + history + new input)
    2. Call provider
    3. Check for tool calls in response
    4. If tool calls → execute via ToolBroker → append results → loop
    5. If no tool calls → return final response
  - [ ] Iteration limit from `AgentConfig.max_iterations` (default 10)
  - [ ] Emit telemetry events at each loop step (prep for Phase 7)

### Supervision

- [ ] `Agora.AgentSupervisor` — DynamicSupervisor for agent processes
- [ ] `Agora.start_agent/1` and `Agora.stop_agent/1` convenience functions
- [ ] Add AgentSupervisor + Task.Supervisor to Application supervision tree

### Testing

- [ ] Unit tests for agent loop with Echo provider and mock tools
- [ ] Test iteration limit triggers proper termination
- [ ] Test tool call → result → re-prompt cycle
- [ ] End-to-end integration test: agent + Echo provider + Calculator tool

---

## Phase 4: Middleware System

Cross-cutting concerns via composable interceptors — the primary extension mechanism.

### Middleware Behaviour

- [ ] `Agora.Middleware` behaviour
  - [ ] `@callback call(context, next) :: {:ok, context} | {:halt, reason}`
  - [ ] Context struct: messages, current_response, tool_calls, config, metadata
- [ ] `Agora.Middleware.Chain` — execute ordered list of middleware with `next` composition

### Hook Points

- [ ] `before_provider_call` — modify messages/config before LLM call
- [ ] `after_provider_call` — inspect/modify provider response
- [ ] `before_tool_call` — approve/block/modify tool execution
- [ ] `after_tool_call` — inspect/modify tool results

### Built-in Middleware

- [ ] `Agora.Middleware.Logger` — log provider calls, tool executions, loop iterations
- [ ] `Agora.Middleware.MaxTokens` — enforce token budget across conversation
- [ ] `Agora.Middleware.Timeout` — wall-clock timeout for entire agent run
- [ ] `Agora.Middleware.ToolApproval` — gate tool calls on approval callback (human-in-the-loop)

### Integration

- [ ] Wire middleware chain into Agent loop (before/after hooks at each step)
- [ ] Tests for each built-in middleware
- [ ] Test middleware ordering and halt propagation

---

## Phase 5: Orchestration

Multi-agent coordination patterns — orchestrators control *which* agent runs, not *how* agents work.

### Orchestrator Behaviour

- [ ] `Agora.Orchestrator` behaviour
  - [ ] `@callback init(config) :: {:ok, state}`
  - [ ] `@callback next(state, messages) :: {:agent, agent_ref, state} | {:done, result, state}`
  - [ ] `@callback handle_result(state, agent_ref, result) :: {:continue, state} | {:done, result, state}`
- [ ] `Agora.Orchestrator.Runner` — GenServer that drives the orchestrator loop

### Termination Conditions

- [ ] `Agora.Orchestrator.TerminationCondition` behaviour
  - [ ] `max_iterations/1`, `keyword_match/1`, `custom/1`
- [ ] Composable conditions (any_of, all_of)

### Built-in Orchestrators

- [ ] `Agora.Orchestrator.Single` — run one agent to completion (baseline)
- [ ] `Agora.Orchestrator.RoundRobin` — cycle through agents in order
- [ ] `Agora.Orchestrator.Supervisor` — one agent delegates to others
- [ ] `Agora.Orchestrator.ChatRoom` — all agents see shared context, take turns

### Testing

- [ ] Test each orchestrator with Echo-backed agents
- [ ] Test termination conditions
- [ ] Test message routing between agents

---

## Phase 6: Memory System

Persistent and in-process memory backends for agent conversation history and knowledge.

### Memory Behaviour

- [ ] `Agora.Memory` behaviour
  - [ ] `@callback init(config) :: {:ok, state}`
  - [ ] `@callback get(state) :: {:ok, [Message.t()]}`
  - [ ] `@callback put(state, Message.t()) :: {:ok, state}`
  - [ ] `@callback clear(state) :: {:ok, state}`

### Backends

- [ ] `Agora.Memory.Buffer` — in-memory ring buffer with configurable max messages
- [ ] `Agora.Memory.File` — JSON-file-backed persistent memory

### Integration

- [ ] Wire memory into Agent loop — load history on start, append after each turn
- [ ] Memory configuration via `AgentConfig.memory`
- [ ] Tests for each backend
- [ ] Test agent with memory across multiple `run/2` calls

---

## Phase 7: Observability

Telemetry-based instrumentation and an internal event bus for UI integration and debugging.

### Telemetry Events

- [ ] `[:agora, :agent, :run, :start | :stop | :exception]`
- [ ] `[:agora, :agent, :loop_iteration, :start | :stop]`
- [ ] `[:agora, :provider, :call, :start | :stop | :exception]`
- [ ] `[:agora, :tool, :call, :start | :stop | :exception]`
- [ ] `[:agora, :middleware, :call, :start | :stop]`
- [ ] `[:agora, :orchestrator, :step, :start | :stop]`

### Instrumentation

- [ ] `Agora.Telemetry` — helper module with `span/3` wrappers for consistent event emission
- [ ] Attach telemetry calls at each instrumentation point in Agent, ToolBroker, Provider, Middleware, Orchestrator

### EventBus

- [ ] `Agora.EventBus` — lightweight pub/sub (Registry-backed) for internal component messaging
  - [ ] `subscribe/2`, `broadcast/2`
  - [ ] Used for: UI integration, audit trail, debugging multi-agent systems
- [ ] Tests for telemetry event emission
- [ ] Tests for EventBus pub/sub delivery

---

## Phase 8: Workflow Engine

DAG-based workflow execution for deterministic multi-step pipelines.

### Core Structs

- [ ] `Agora.Workflow.Step` — id, agent_config or function, inputs, outputs
- [ ] `Agora.Workflow.Edge` — from_step, to_step, condition (optional)
- [ ] `Agora.Workflow` — steps, edges, metadata

### DAG Executor

- [ ] `Agora.Workflow.Executor` — topological sort, parallel fan-out where edges allow
  - [ ] Execute steps as supervised tasks
  - [ ] Pass outputs from completed steps as inputs to dependents
  - [ ] Handle step failure (retry policy, skip, abort)
- [ ] Support conditional edges (branching workflows)

### Builder API

- [ ] `Agora.Workflow.Builder` — DSL-style helpers
  - [ ] `step/3`, `edge/3`, `sequence/1`, `parallel/1`
  - [ ] Validate DAG (cycle detection) at build time

### Checkpoint Store

- [ ] `Agora.Workflow.CheckpointStore` — persist step results for resumability
  - [ ] In-memory and file-backed implementations
- [ ] Tests for linear, branching, and parallel workflows
- [ ] Test checkpoint and resume

---

## Phase 9: Streaming Support

Real-time token streaming from providers through the agent to callers.

### Provider Streaming

- [ ] Extend `Agora.Provider` behaviour with `stream_chat/2` callback
  - [ ] Return `Stream.t()` of delta events
- [ ] `Agora.Provider.Anthropic` streaming via SSE
- [ ] `Agora.Provider.OpenAI` streaming via SSE
- [ ] Accumulator that assembles deltas into final `Message`

### Agent Streaming

- [ ] `Agora.Agent.stream_run/2` — returns a stream/process that emits events as they arrive
- [ ] Define event types: `:text_delta`, `:tool_call_start`, `:tool_call_delta`, `:tool_result`, `:done`, `:error`
- [ ] Wire middleware hooks for streaming events
- [ ] Tests with Echo provider emitting simulated stream events

---

## Phase 10: Top-Level API, Docs & Release

Polish the public API surface, write documentation, build examples, and prepare for Hex.pm.

### Public API

- [ ] `Agora.run/2` — one-shot: create agent, run task, return result
- [ ] `Agora.stream/2` — one-shot streaming variant
- [ ] `Agora.start_agent/1`, `Agora.stop_agent/1` — long-lived agent management
- [ ] `Agora.run_workflow/1` — execute a workflow definition
- [ ] Ensure all public functions have `@doc` and `@spec`

### Documentation

- [ ] Module-level `@moduledoc` for every public module
- [ ] Getting Started guide (Livebook or markdown)
- [ ] Architecture overview diagram
- [ ] Provider setup guides (Anthropic, OpenAI)
- [ ] Tool authoring guide
- [ ] Middleware authoring guide
- [ ] Orchestrator guide with examples
- [ ] Workflow engine guide

### Examples

- [ ] `examples/simple_chat.exs` — single agent Q&A
- [ ] `examples/tool_use.exs` — agent with custom tools
- [ ] `examples/multi_agent.exs` — orchestrated multi-agent conversation
- [ ] `examples/workflow.exs` — DAG workflow execution
- [ ] `examples/streaming.exs` — streaming agent output

### Hex Release Prep

- [ ] Fill out `mix.exs` — description, package metadata, licenses, links, source_url
- [ ] Add `CHANGELOG.md`
- [ ] Add `LICENSE` (MIT or Apache-2.0)
- [ ] CI setup (GitHub Actions: `mix test`, `mix format --check-formatted`, `mix dialyzer`)
- [ ] Publish to Hex.pm

---

## Design Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| HTTP client | `Req` | Batteries-included, built-in retry/redirect, modern API |
| Config validation | `NimbleOptions` | Declarative schemas, excellent error messages, widely adopted |
| Observability | `:telemetry` | BEAM ecosystem standard, zero-cost when no handlers attached |
| JSON library | `Jason` | De facto Elixir standard, fast native encoding |
| Agent loop | Synchronous first | Simpler to reason about; streaming added in Phase 9 |
| Tool definition | Behaviour | Compile-time checking; FunctionTool adapter for ad-hoc tools |
| Middleware model | Chain with `next` | Familiar (Plug-style), composable, supports halt semantics |
| Orchestrators | Separate from agents | Agents stay simple; coordination is a distinct concern |
| State model | Minimal enum | idle/running/awaiting_tool/awaiting_approval — avoid state machine complexity |
| Memory | Behaviour + backends | Swappable storage; Buffer for dev, File for persistence, extensible to ETS/DB |

---

## Dependency Summary

| Package | Version | Purpose | Phase |
|---|---|---|---|
| `jason` | `~> 1.4` | JSON encoding/decoding | 0 |
| `req` | `~> 0.5` | HTTP client for provider APIs | 0 |
| `nimble_options` | `~> 1.1` | Config schema validation | 0 |
| `telemetry` | `~> 1.3` | Event instrumentation | 0 |
| `ex_doc` | `~> 0.35` | Documentation generation | 0 (dev) |
| `dialyxir` | `~> 1.4` | Static type analysis | 0 (dev) |

---

## Target File Tree

```
lib/agora/
├── config.ex                          # Phase 0
├── error.ex                           # Phase 0
├── message.ex                         # Phase 0
├── tool_call.ex                       # Phase 0
├── tool_result.ex                     # Phase 0
├── agent_config.ex                    # Phase 0
│
├── provider/
│   ├── provider.ex                    # Phase 1 (behaviour)
│   ├── echo.ex                        # Phase 1
│   ├── anthropic.ex                   # Phase 1
│   └── openai.ex                      # Phase 1
│
├── tool/
│   ├── tool.ex                        # Phase 2 (behaviour)
│   ├── function_tool.ex               # Phase 2
│   ├── schema.ex                      # Phase 2
│   ├── broker.ex                      # Phase 2
│   ├── calculator.ex                  # Phase 2 (example)
│   └── date_time.ex                   # Phase 2 (example)
│
├── agent/
│   ├── agent.ex                       # Phase 3 (GenServer)
│   └── supervisor.ex                  # Phase 3
│
├── middleware/
│   ├── middleware.ex                   # Phase 4 (behaviour)
│   ├── chain.ex                       # Phase 4
│   ├── logger.ex                      # Phase 4
│   ├── max_tokens.ex                  # Phase 4
│   ├── timeout.ex                     # Phase 4
│   └── tool_approval.ex               # Phase 4
│
├── orchestrator/
│   ├── orchestrator.ex                # Phase 5 (behaviour)
│   ├── runner.ex                      # Phase 5
│   ├── termination_condition.ex       # Phase 5
│   ├── single.ex                      # Phase 5
│   ├── round_robin.ex                 # Phase 5
│   ├── supervisor_orchestrator.ex     # Phase 5
│   └── chat_room.ex                   # Phase 5
│
├── memory/
│   ├── memory.ex                      # Phase 6 (behaviour)
│   ├── buffer.ex                      # Phase 6
│   └── file.ex                        # Phase 6
│
├── telemetry.ex                       # Phase 7
├── event_bus.ex                       # Phase 7
│
└── workflow/
    ├── step.ex                        # Phase 8
    ├── edge.ex                        # Phase 8
    ├── workflow.ex                    # Phase 8
    ├── executor.ex                    # Phase 8
    ├── builder.ex                     # Phase 8
    └── checkpoint_store.ex            # Phase 8
```
