# Agora — Implementation Roadmap

> Multi-agent runtime framework for Elixir leveraging the BEAM actor model.
> Reference: [`docs/Design-v0.md`](docs/Design-v0.md)

---

## Phase 0: Project Foundation

Set up dependencies, configuration, and core data structures that every subsequent phase builds on.

### Dependencies

- [x] Add `jason ~> 1.4` — JSON encoding/decoding
- [x] Add `req ~> 0.5` — HTTP client for provider API calls
- [x] Add `nimble_options ~> 1.1` — declarative schema validation for configs
- [x] Add `telemetry ~> 1.3` — event instrumentation and observability
- [x] Add `ex_doc` and `dialyxir` as dev-only deps
- [x] Run `mix deps.get` and verify compilation

### Core Structs

- [x] `Agora.Message` — role, content, tool_calls, tool_results, metadata, timestamps
- [x] `Agora.ToolCall` — id, name, arguments (decoded map), status
- [x] `Agora.ToolResult` — tool_call_id, name, content, is_error flag
- [x] `Agora.AgentConfig` — provider, model, instructions, tools, memory, middleware, max_iterations, name
  - [x] Validate with NimbleOptions schema
- [x] `Agora.Error` — structured error type (provider_error, tool_error, validation_error, timeout, etc.)

### Configuration

- [x] `Agora.Config` module — application-level config helpers (provider API keys, defaults)
- [x] Support runtime config via `config/runtime.exs` pattern

---

## Phase 1: Provider Abstraction Layer ✅

Unified LLM interface so agents are provider-agnostic.

### Provider Behaviour

- [x] `Agora.Provider` behaviour — `@callback chat(messages, config) :: {:ok, Message.t()} | {:error, Error.t()}`
- [x] Define provider config options schema (api_key, base_url, headers, timeout)
  - Provider-namespaced app config fallback (`get_opt/3` reads `:anthropic_base_url`, `:openai_timeout`, etc.)
  - API key lookup: `provider_opts[:api_key]` → `Config.api_key(:provider)` — no generic `:api_key` leakage
- [x] Normalize message format across providers (role mapping, tool_call format translation)

### Implementations

- [x] `Agora.Provider.Echo` — test/dev provider with 6 configurable modes
  - [x] Unit tests for Echo provider
- [x] `Agora.Provider.Anthropic` — Messages API integration
  - [x] Map Agora messages to Anthropic format (system separate from messages, tool_use/tool_result content blocks)
  - [x] Parse tool_use blocks from response into `ToolCall` structs
  - [x] Handle API errors, rate limits, and retries (opt-in via `retry: :transient` in `req_options`)
  - [x] Adjacent same-role message merging (Anthropic requires alternating roles)
  - [x] Custom header merging without clobbering auth headers
  - [x] Unit tests with mocked HTTP responses (Req.Test plug injection)
  - [x] Config fallback tests (`async: false`) for app-level API key, base_url, timeout
- [x] `Agora.Provider.OpenAI` — Chat Completions API integration
  - [x] Map Agora messages to OpenAI format (tool_calls in assistant messages, tool role for results)
  - [x] Parse tool_calls from response into `ToolCall` structs (JSON string decode with malformed fallback)
  - [x] Handle API errors, rate limits, and retries (opt-in via `retry: :transient` in `req_options`)
  - [x] One Agora `:tool` message with N results expands to N separate OpenAI `tool` messages
  - [x] Custom header merging without clobbering auth headers
  - [x] Unit tests with mocked HTTP responses (Req.Test plug injection)
  - [x] Config fallback tests (`async: false`) for app-level API key, base_url, timeout

### Integration

- [x] Provider resolution from AgentConfig (atom/module lookup with `resolve/1`)
- [x] Integration test with Echo provider end-to-end

---

## Phase 2: Tool System ✅

First-class tool execution with validation and supervised parallel support.

### Tool Behaviour

- [x] `Agora.Tool` behaviour
  - [x] `@callback name() :: String.t()`
  - [x] `@callback description() :: String.t()`
  - [x] `@callback schema() :: map()` — JSON Schema for parameters
  - [x] `@callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, any()}`
  - [x] `@callback timeout() :: pos_integer()` — optional, default 30_000
  - [x] Helper functions: `to_definition/1`, `resolve/2`, `execute/3`, `timeout/1`, `tool_name/1`

### FunctionTool Adapter

- [x] `Agora.Tool.FunctionTool` — struct wrapping `{name, description, schema, function, timeout}` as a Tool
  - [x] `new/1` / `new!/1` constructors with field validation
  - [x] `@derive {Jason.Encoder, except: [:function]}` — safe JSON serialization

### Schema Helpers

- [x] `Agora.Tool.Schema` — helpers to build JSON Schema maps for tool parameters
  - [x] `string/1`, `integer/1`, `number/1`, `boolean/1`, `array/2`, `object/2`, `enum/2`
  - [x] `required/2` wrapper — adds required fields to existing object schema
  - [x] `validate/2` — lightweight type checking with path-aware error messages
    - [x] Required fields, enum membership, nested object/array validation

### ToolBroker

- [x] `Agora.ToolBroker` — stateless tool execution manager
  - [x] Name→tool lookup from tools list (modules, FunctionTool structs, plain maps)
  - [x] Argument validation against tool schema (opt-out with `validate: false`)
  - [x] Execute via `Task.Supervisor` (`Agora.ToolSupervisor`) for isolation and fault tolerance
  - [x] Support parallel tool fan-out (multiple tool calls in one turn)
  - [x] Deadline-based timeout enforcement per tool call with `:brutal_kill` shutdown
  - [x] Return `{:ok, [ToolResult.t()]}` always — individual failures become error results
  - [x] Catches exceptions, throws, and exits from misbehaving tools

### Provider Integration

- [x] Providers normalize tools via `AgentConfig.tool_definitions/1` — modules and FunctionTool structs serialize correctly alongside plain maps
- [x] `AgentConfig.tool_definitions/1` converts tools list to provider-consumable definition maps
- [x] `Agora.ToolSupervisor` added to Application supervision tree

### Example Tools

- [x] `Agora.Tool.Calculator` — basic arithmetic (add, subtract, multiply, divide) with division-by-zero handling
- [x] `Agora.Tool.DateTime` — current date/time in three formats (date, time, datetime)
- [x] Tests for each tool, schema builders/validation, FunctionTool, ToolBroker execution (112 new tests)

---

## Phase 3: Agent Runtime ✅

The core agent process with the default reasoning/action loop.

### Agent GenServer

- [x] `Agora.Agent` — GenServer implementing the agent loop
  - [x] `start_link/1` accepting keyword opts with required `:config` key and optional `:name`
  - [x] `run/2` — send a string or `Message` and get final response; blocks via `GenServer.call(:infinity)`
  - [x] `get_messages/1`, `get_status/1` — state introspection
  - [x] Internal state: config, messages (conversation history), status (`:idle` | `:running`), iteration counter
  - [x] Reasoning loop (tail-recursive private function):
    1. Check iteration limit → return `{:error, %Error{type: :iteration_limit}}` if exceeded
    2. Call `Provider.chat/3`
    3. If tool calls → append assistant message → execute via `ToolBroker.execute/2` → append tool results → recurse
    4. If no tool calls → append assistant message → return `{:ok, response}`
    5. If provider error → return `{:error, error}`
  - [x] Iteration limit from `AgentConfig.max_iterations` (default 10)
  - [x] Telemetry events emitted with sanitized metadata (provider, model, agent_name, max_iterations only — no API keys):
    - `[:agora, :agent, :run, :start | :stop]`
    - `[:agora, :agent, :loop_iteration, :start | :stop]`
  - [x] Crash protection: `try/catch` around reasoning loop converts raise/exit/throw to `{:error, %Error{type: :unknown}}`
  - [x] Crash errors are JSON-encodable (metadata contains only string values)
  - [x] Partial history preserved on mid-loop crash via process dictionary tracking
  - [x] `child_spec/1` overrides `restart: :temporary` (no restart on crash until Phase 6 Memory)

### Concurrency Model

- [x] Synchronous `run/2` — executes inside `handle_call`, concurrent calls queue (GenServer mailbox serialization)
- [x] Messages persist across `run/2` calls in GenServer state
- [x] Status `:idle` | `:running` — `:running` set during loop but not externally observable via `get_status/1` due to call serialization

### Supervision

- [x] `Agora.Agent.Supervisor` — DynamicSupervisor for agent processes
  - [x] `start_agent/2` — starts an `Agora.Agent` child from config + opts
  - [x] `stop_agent/1` — terminates a child by pid
- [x] `Agora.start_agent/2` and `Agora.stop_agent/1` convenience functions delegating to supervisor
- [x] `Agora.Agent.Supervisor` added to Application supervision tree after `Agora.ToolSupervisor`

### Testing

- [x] Unit tests for agent loop with Echo provider and FunctionTool tools (agent_test.exs)
  - [x] start_link: process start, status, system message, name registration
  - [x] run: string input, Message input, history accumulation
  - [x] Conversation persistence across multiple runs
  - [x] Provider error propagation and status recovery
  - [x] Crash protection: raise/exit/throw caught, JSON-encodable errors, partial history preserved, agent reusable after crash
  - [x] Concurrent run queuing: two async calls both complete
  - [x] Tool call loop: single tool, multiple tools in one turn
  - [x] Iteration limit triggers `:iteration_limit` error
  - [x] System message preserved through tool loop iterations
  - [x] Telemetry events emitted with sanitized metadata (no config/secrets)
- [x] Supervisor tests (agent/supervisor_test.exs): start/stop agents, name registration
- [x] End-to-end integration tests (agent_integration_test.exs): Agent + Echo + Calculator
  - [x] Full tool call cycle with real Calculator tool
  - [x] Multi-step calculation with conversation persistence
  - [x] Tool error (division by zero) fed back to provider
  - [x] `Agora.start_agent/2` and `Agora.stop_agent/1` convenience functions
- [x] 272 total tests (31 new), 0 failures

---

## Phase 4: Middleware System ✅

Cross-cutting concerns via composable interceptors — the primary extension mechanism.

### Middleware Behaviour

- [x] `Agora.Middleware` behaviour
  - [x] `@callback call(context, next) :: {:ok, context} | {:halt, reason}`
  - [x] Type `middleware :: module() | (Context.t(), next() -> ...)` — supports both module atoms and 2-arity closures
- [x] `Agora.Middleware.Context` — struct threaded through chain with hook, messages, response, tool_calls, tool_results, config, metadata
  - [x] Hook-specific field semantics (modifiable vs read-only per hook point)
  - [x] Namespaced metadata (each middleware uses its module as key to prevent collisions)
- [x] `Agora.Middleware.Chain` — Plug-style `next` chain executor
  - [x] Empty list passthrough (zero overhead)
  - [x] Module dispatch (`is_atom`) and closure dispatch (`is_function/2`)
  - [x] Error safety: try/catch wraps each invocation; raise/throw/exit/bad-return/invalid-entry all convert to `{:halt, %Error{type: :middleware_error}}`
  - [x] Return validation: only `{:ok, %Context{}}` and `{:halt, term()}` accepted

### Hook Points

- [x] `before_provider_call` — modify messages/config before LLM call (config modifications scoped to current iteration only)
- [x] `after_provider_call` — inspect/modify provider response and tool_calls
- [x] `before_tool_call` — approve/block/filter tool calls; filtered calls sync with history (D14)
- [x] `after_tool_call` — inspect/modify tool results before appending to history

### Built-in Middleware

- [x] `Agora.Middleware.Logger` — module-based, logs events at each hook via `Logger.debug/1`
- [x] `Agora.Middleware.MaxTokens` — `new(max_tokens: N)` factory; estimates tokens from content + tool_call args + tool_result content; active at `:before_provider_call` only
- [x] `Agora.Middleware.Timeout` — `new(timeout_ms: N)` factory; cooperative wall-clock timeout; sets deadline on first invocation, checks on subsequent; active at all hooks; deadline persists via namespaced metadata
- [x] `Agora.Middleware.ToolApproval` — `new(approve_fn: fn)` factory; approval function returns `:approve | {:reject, reason} | {:filter, calls}`; active at `:before_tool_call` only

### Integration

- [x] Wire middleware chain into Agent reasoning loop at 4 hook points
  - [x] Fast path: `config.middleware == []` → skip all context/chain construction (zero overhead)
  - [x] Middleware path: construct Context at each hook, run Chain, read back modified fields
  - [x] `middleware_metadata` in GenServer state persists metadata across iterations within a run
  - [x] Halt persistence (D11): on any halt, no new messages appended — `state.messages` unchanged
  - [x] Tool call filtering sync (D14): if `before_tool_call` filters calls, assistant message reflects only approved calls
  - [x] Config mutability (D7): `before_provider_call` can modify config for current iteration; not persisted to state
  - [x] Telemetry invariants preserved: stop events emitted on middleware halts with error metadata
- [x] `Agora.Error` — added `:middleware_error` type
- [x] `Agora.AgentConfig` — updated middleware field docs to mention closures

### Testing

- [x] Context unit tests (middleware_test.exs)
- [x] Chain tests (middleware/chain_test.exs): passthrough, ordering, halt, module/closure/mixed, error safety (raise/throw/exit/bad-return/invalid-entry/downstream-not-called)
- [x] Logger tests (middleware/logger_test.exs): log output at each hook, passthrough
- [x] MaxTokens tests (middleware/max_tokens_test.exs): under/over budget, custom chars_per_token, hook selectivity, tool data in estimate
- [x] Timeout tests (middleware/timeout_test.exs): before/after deadline, deadline reuse, metadata persistence, all-hook coverage
- [x] ToolApproval tests (middleware/tool_approval_test.exs): approve/reject/filter/empty-filter, hook selectivity
- [x] Integration tests (middleware/integration_test.exs): Agent + each middleware, composition, halt at each hook, metadata persistence, config modification scope, empty middleware regression, error handling (raise/throw/exit), telemetry
- [x] 336 total tests (64 new), 0 failures

---

## Phase 5: Orchestration ✅

Multi-agent coordination patterns — orchestrators control *which* agent runs, not *how* agents work.

### Orchestrator Behaviour

- [x] `Agora.Orchestrator` behaviour
  - [x] `@callback init(config :: map()) :: {:ok, state} | {:error, Error.t()}`
  - [x] `@callback next(state, context) :: {:next, agent_name, input_msg, state} | {:done, result, state}`
  - [x] `@callback handle_result(state, agent_name, result) :: {:continue, state} | {:done, result, state} | {:error, Error.t(), state}`
  - [x] `context` is `%{original_input: Message.t(), history: [turn()]}` where `turn()` = `%{agent: atom(), input: Message.t(), output: result}`
  - [x] Agent names are `atom()` — Runner resolves to PIDs internally
- [x] `Agora.Orchestrator.Runner` — GenServer that drives the orchestrator loop
  - [x] Mirrors Agent pattern: synchronous `run/2`, `:temporary` restart
  - [x] Starts agents via `Agora.Agent.Supervisor.start_agent/2` (supervised, not linked)
  - [x] Re-initializes orchestrator state and clears history per `run/2` (agent processes persist)
  - [x] Crash protection via try/catch → `{:error, %Error{type: :orchestration_error}}`
  - [x] Hard safety limit `max_turns` (default 100) separate from termination conditions
- [x] `Agora.Orchestrator.RunnerSupervisor` — DynamicSupervisor for Runner processes

### Termination Conditions

- [x] `Agora.Orchestrator.TerminationCondition` — composable closures (not behaviour)
  - [x] `max_turns/1` — checks `length(context.history) >= n`
  - [x] `keyword_match/1` — case-insensitive match on last response content
  - [x] `custom/1` — passthrough for arbitrary functions
  - [x] `any_of/1`, `all_of/1` — composition

### Built-in Orchestrators

- [x] `Agora.Orchestrator.Single` — run one agent to completion (baseline)
- [x] `Agora.Orchestrator.RoundRobin` — cycle through agents in order, each receives previous response
- [x] `Agora.Orchestrator.Supervisor` — response-based delegation with safe parser (never `String.to_atom` on model output)
- [x] `Agora.Orchestrator.ChatRoom` — shared transcript, configurable `:max_transcript_messages` cap

### Design Decisions

- D1: `next/2` returns `{:next, agent_name, input_msg, state}` — orchestrators control routing input
- D2: Agent refs are `atom()` names — pattern-matchable, Runner resolves to PIDs
- D3: Context is `%{original_input, history}` — richer than raw messages
- D4: Termination conditions are closures — composable with `any_of/all_of`, matches middleware pattern
- D5: Agents started via existing `Agora.Agent.Supervisor` — supervised, not linked to Runner
- D6: Supervisor delegation parser validates against known worker name map — atom safety
- D7: ChatRoom sends full transcript; configurable `:max_transcript_messages` bounds O(n^2) growth
- D8: Runner crash protection via try/catch — matches Agent pattern
- D9: `max_turns` (default 100) is hard safety limit, separate from business-logic termination
- D10: Run scope — orchestrator state re-initialized per `run/2`, agent processes persist
- D11: Strategy = `Agora.Orchestrator.Supervisor`, DynamicSupervisor = `Agora.Orchestrator.RunnerSupervisor`
- D12: All orchestrators use `msg.content || ""` for nil-safe routing
- D13: Init failure cleanup — Runner stops already-started agents on partial init failure
- D14: Telemetry uses `:step` events to align with Phase 7 roadmap

### Testing

- [x] Termination condition tests (max_turns, keyword_match, custom, any_of, all_of)
- [x] Orchestrator unit tests (Single, RoundRobin, Supervisor, ChatRoom)
- [x] Runner tests with Echo-backed agents (lifecycle, run, crash protection, telemetry)
- [x] Integration tests (tools within orchestration, convenience functions)
- [x] `Agora.Error` — added `:orchestration_error` type
- [x] 462 total tests (121 new, pre-Phase-6), 0 failures

---

## Phase 6: Memory System ✅

Persistent and in-process memory backends for agent conversation history and knowledge.

### Memory Behaviour

- [x] `Agora.Memory` behaviour
  - [x] `@callback init(config :: keyword()) :: {:ok, state} | {:error, Error.t()}`
  - [x] `@callback get(state) :: {:ok, [Message.t()]} | {:error, Error.t()}`
  - [x] `@callback save(state, [Message.t()]) :: {:ok, state} | {:error, Error.t()}`
  - [x] `@callback clear(state) :: {:ok, state} | {:error, Error.t()}`
  - [x] Dispatch functions accept `{module, state}` tuples — route to backend
  - [x] Module validation via `Code.ensure_loaded/1` + `function_exported?/3` at init

### Backends

- [x] `Agora.Memory.Buffer` — in-memory ring buffer with `:queue`, bounded by `:max_messages`
  - [x] `save/2` replaces entire queue with last N messages from input list
  - [x] O(1) amortized enqueue/dequeue; manual size counter avoids O(n) `:queue.len/1`
- [x] `Agora.Memory.File` — JSON-file-backed persistent memory
  - [x] Atomic writes via temp-file + rename (crash-safe)
  - [x] Safe deserialization with explicit atom lookup maps (never `String.to_existing_atom/1`)
  - [x] No cached messages — state is `%{path}` only (reads always hit disk)

### Integration

- [x] Memory is canonical store — `state.messages` re-derived from `Memory.get()` after each run
- [x] Memory config format: `{module, keyword()}` tuple or `nil`
- [x] Memory save at run boundaries (after reasoning loop, before telemetry)
- [x] Fatal error handling — save failure overrides successful run result
- [x] `Agent.clear_memory/1` API for clearing memory backend
- [x] `child_spec/1` returns `:transient` when memory configured (enables supervised restart)
- [x] `Agora.Error` — added `:memory_error` type

### Design Decisions

- D1: Config format `{module, keyword()}` — clean dispatch, module + options in one value
- D2: Memory is canonical store; `state.messages` re-derived from `Memory.get()` after save
- D3: Atomic `save/2` takes full message list — eliminates partial persistence and diff bugs
- D4: Save at run boundaries — avoids mid-loop complexity; single atomic operation
- D5: System messages excluded from memory — reconstructed from config on init
- D6: Fatal errors — save failure overrides successful run result for data consistency
- D7: Buffer uses `:queue` + size counter for O(1) amortized operations
- D8: File uses temp-file + rename for atomic writes (crash-safe)
- D9: File state is `%{path}` only — no cached messages avoids triple duplication
- D10: Crash recovery unchanged — process dict tracks messages; memory has previous run's state
- D11: Module validation at init catches undef errors early
- D12: `:transient` restart when memory configured enables supervised recovery
- D13: Safe serialization with atom lookup maps; typed `:memory_error` on unknown values
- D14: All callbacks return `{:ok, ...} | {:error, Error.t()}`

### Testing

- [x] Memory dispatch unit tests (module validation, tuple threading, error propagation)
- [x] Buffer backend tests (init validation, save/get/clear, ring buffer bounding, round-trip)
- [x] File backend tests (init validation, atomic writes, serialization round-trip including tool_calls/results/DateTime, edge cases)
- [x] Integration tests (Agent + Buffer, Agent + File, clear_memory, restart persistence, middleware composition, invalid config, restart semantics)
- [x] 523 total tests (61 new), 0 failures

---

## Phase 7: Observability ✅

Telemetry-based instrumentation and an internal event bus for UI integration and debugging.

### Telemetry Events

- [x] `[:agora, :agent, :run, :start | :stop | :exception]`
- [x] `[:agora, :agent, :loop_iteration, :start | :stop]`
- [x] `[:agora, :provider, :call, :start | :stop | :exception]`
- [x] `[:agora, :tool, :call, :start | :stop | :exception]`
- [x] `[:agora, :middleware, :call, :start | :stop]`
- [x] `[:agora, :orchestrator, :run | :step, :start | :stop]`

### Instrumentation

- [x] `Agora.Telemetry` — helper module with `span/3` and `emit/3` wrappers, canonical event documentation
- [x] Provider telemetry: `Provider.chat/3` wrapped with span (start/stop/exception)
- [x] Tool telemetry: outer start/stop in `ToolBroker.execute/4` (guaranteed terminal event even on :brutal_kill), inner exception in `execute_single/4` catch
- [x] Middleware telemetry: `Chain.run/2` wrapped with span; empty middleware fast path skips telemetry
- [x] Agent exception event: `[:agora, :agent, :run, :exception]` in `safe_reasoning_loop` catch with sanitized metadata

### EventBus

- [x] `Agora.EventBus` — Registry-backed pub/sub with `:duplicate` keys for internal component messaging
  - [x] `subscribe/2` (idempotent), `broadcast/2`, `unsubscribe/1`
  - [x] Messages delivered as `{Agora.EventBus, topic, message}` tuples
  - [x] Process exit auto-unregisters; NOT wired to telemetry (user bridges if desired)
- [x] `Agora.EventBus.Registry` added to application supervision tree

### Design Decisions

- D1: Existing Agent/Orchestrator telemetry left as manual `:telemetry.execute` (intentional — refactoring would break tested measurement key assertions for no behavioral gain)
- D2: New instrumentation uses `:telemetry.span/3` which adds `monotonic_time` to measurements
- D3: Provider resolution errors do NOT emit provider telemetry — they're config issues, not provider calls
- D4: Tool telemetry uses two levels: outer `start`/`stop` pairs around each call (paired under normal supervisor operation), inner `:exception` for crash visibility
- D5: EventBus `subscribe/2` checks `Registry.keys/2` before register to prevent duplicate deliveries (no TOCTOU — same process)
- D6: Sanitized metadata: exception `reason` stringified, `stacktrace` truncated to 1000 chars, no raw terms or API keys

### Testing

- [x] Telemetry helper tests (span start/stop/exception, emit delegation)
- [x] Provider telemetry tests (success, error, exception, resolution failure, metadata sanitization)
- [x] Tool broker telemetry tests (success, error, raise, timeout, exit, multiple tools)
- [x] Middleware chain telemetry tests (non-empty, halt, empty, crash, metadata)
- [x] Agent exception telemetry tests (sanitized metadata, backward-compat run:stop still fires)
- [x] EventBus tests (subscribe/broadcast, multiple subscribers, unsubscribe, topic isolation, idempotent subscribe, process exit cleanup)
- [x] 576 total tests (53 new), 0 failures

---

## Phase 8: Workflow Engine ✅

DAG-based workflow execution for deterministic multi-step pipelines.

### Core Structs

- [x] `Agora.Workflow.Step` — id, handler (function or AgentConfig), inputs, outputs, input_mapper, timeout, retry
  - Step `inputs` drives auto-edge generation in Builder; `outputs` is optional documentation schema (executor does not enforce)
- [x] `Agora.Workflow.Edge` — from, to, condition (optional 1-arity function)
- [x] `Agora.Workflow` — steps map, edges list, metadata

### DAG Executor

- [x] `Agora.Workflow.Executor` — topological sort (Kahn's algorithm), parallel fan-out via Task.Supervisor
  - [x] Execute steps as supervised tasks under `Agora.WorkflowTaskSupervisor`
  - [x] Pass outputs from completed steps as inputs to dependents
  - [x] Handle step failure (per-step retry count, `:abort` or `:skip` mode)
  - [x] Deadline-based timeout (ToolBroker pattern) — no task leakage
  - [x] Sorted step IDs within levels for deterministic execution
- [x] Support conditional edges (1-arity condition functions with explicit resolution matrix)
- [x] AgentConfig handler dispatch: starts temporary agent per step, with explicit `input_mapper` or default JSON encoding
- [x] Result contract: `{:ok, value} | {:error, Error.t()} | :skipped`
- [x] Telemetry: `[:agora, :workflow, :run]` and `[:agora, :workflow, :step]` via `span/3`

### Builder API

- [x] `Agora.Workflow.Builder` — DSL-style pipeline helpers
  - [x] `step/3`, `edge/3`, `sequence/2`, `parallel/3` (real fan-out/fan-in composition)
  - [x] Auto-edge generation from step `inputs` declarations (explicit edges take precedence)
  - [x] Non-bang helpers never raise — errors accumulate and surface via `build/1`
  - [x] Validate DAG (cycle detection via Kahn's algorithm) at build time

### Checkpoint Store

- [x] `Agora.Workflow.CheckpointStore` — behaviour + dispatch (Memory pattern)
  - [x] `load_all/2` maps backend keys to atoms via known step IDs (safe against stale entries)
  - [x] In-memory backend (`CheckpointStore.Memory`)
  - [x] File-backed backend (`CheckpointStore.File`) with atomic writes, result serialization, optional namespace
- [x] Tests for linear, parallel, branching, conditional, and retry workflows
- [x] Test checkpoint save and resume with File backend

### Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Executor model | Stateless module | Matches ToolBroker; workflows are one-shot |
| Step handler | Function or AgentConfig | Functions for deterministic logic; AgentConfig for LLM steps |
| Agent input_mapper | Explicit `(map() -> String.t() \| Message.t())` | Stable data contract vs ad-hoc string concat |
| Result contract | `{:ok, value} \| {:error, Error.t()} \| :skipped` | Unambiguous; handlers pattern match on exact shape |
| Failure mode | `:abort` (default) or `:skip` | Abort for strict pipelines; skip for best-effort |
| Conditional edges | 1-arity fn; explicit resolution matrix | Deterministic; no deadlock possible |
| Parallel fan-out | `parallel/3` creates edges | Real composition (from/to), not just assertion |
| Checkpoint keys | String keys in backend; dispatch maps to atoms | Safe against stale/unknown entries |
| Determinism | Sort step IDs within levels | Consistent execution and output order |

### Testing

- [x] Step, Edge, Workflow struct tests
- [x] Builder tests (step/edge/sequence/parallel, auto-edges, cycle detection, build validation)
- [x] CheckpointStore dispatch tests (init, save, load, load_all key mapping, safe_call wrapping)
- [x] Memory backend tests (save/load round-trip, clear)
- [x] File backend tests (save/load, atomic write, namespace, result serialization)
- [x] Executor tests (linear, parallel, single step, input, abort/skip, timeout, retry, conditional edges, crash safety, checkpoint, telemetry, AgentConfig handler)
- [x] Integration tests (builder + executor end-to-end, conditional branching, checkpoint + resume with File, auto-edge execution, convenience API)
- [x] 705 total tests (129 new), 0 failures

---

## Phase 9: Streaming Support ✅

Real-time token streaming from providers through the agent to callers.

### Provider Streaming

- [x] Extend `Agora.Provider` behaviour with optional `stream_chat/2` callback
  - [x] Returns `{:ok, %{pid: pid(), ref: reference()}}` — process-based streaming
  - [x] Backward compatible: providers with only `chat/2` still resolve; `stream_run/2` returns typed `:streaming_error`
- [x] `Agora.Provider.Anthropic` streaming via SSE (message_start, content_block_start/delta/stop, message_delta, message_stop)
- [x] `Agora.Provider.OpenAI` streaming via SSE (choices[0].delta, tool_calls, [DONE] marker)
- [x] `Agora.Provider.SSE` — shared SSE line parser with partial-data buffering
- [x] `Agora.Provider.StreamAccumulator` — assembles text/tool_call deltas into final `Message`

### Stream Event Types

- [x] `Agora.StreamEvent` — struct with 7 typed constructors:
  - `:text_delta` — `%{text: "chunk"}`
  - `:tool_call_start` — `%{id: "toolu_123", name: "calc", index: 0}`
  - `:tool_call_delta` — `%{id: "toolu_123", arguments_fragment: "{\"a\":"}`
  - `:tool_result` — `%ToolResult{}`
  - `:message_complete` — `%Message{}` (accumulated assistant message)
  - `:done` — `%{}`
  - `:error` — `%Error{}`

### Agent Streaming

- [x] `Agora.Agent.stream_run/2` — returns `{:ok, Agora.Stream.t()}` (Enumerable wrapper)
- [x] `Agora.Stream` — Enumerable protocol implementation with process-based event delivery
  - [x] Stream ownership: only the caller process that invoked `stream_run/2` can enumerate
  - [x] Composable with `Stream.filter/2`, `Stream.take/2`, `Enum.to_list/1`, etc.
  - [x] Guaranteed terminal signal: `:done` or `:error` always delivered (provider crash → synthesized error)
- [x] Agent status extended: `:idle | :running | :streaming`
  - [x] Concurrent `run/2` or `stream_run/2` rejected while streaming
- [x] Streaming reasoning loop: multi-turn tool execution with event relay
  - [x] Accumulate deltas → detect tool calls → execute tools → emit `:tool_result` events → re-stream
- [x] Memory save after stream completes (failure logged + telemetry, agent transitions to :idle)

### Middleware

- [x] New `:on_stream_event` hook — per-event interception for logging, filtering, transformation
- [x] Middleware can suppress events by setting `ctx.stream_event = nil`
- [x] Existing 4 hooks fire at loop boundaries on accumulated messages (same as sync `run/2`)
- [x] Logger middleware updated with `:on_stream_event` clause

### Echo Provider Streaming

- [x] `stream_chat/2` with multiple modes: `:echo`, `:static`, `:stream`, `:function`, `:tool_call`, `:error`
- [x] Configurable via `echo_stream_events`, `echo_stream_function`, `echo_stream_delay`

### Telemetry

- [x] `[:agora, :provider, :stream, :start | :stop]` — provider streaming events
- [x] `[:agora, :agent, :stream_run, :start | :stop]` — agent streaming lifecycle
- [x] 28 total events across 11 event prefixes (updated from 23 events / 9 prefixes)

### Supervision

- [x] `Agora.StreamSupervisor` (Task.Supervisor) added to application supervision tree
- [x] Streaming tasks supervised; crash cleanup via `:DOWN` monitor

### Testing

- [x] StreamEvent struct tests (constructors, Jason encoding)
- [x] Agora.Stream Enumerable tests (to_list, done/error termination, take, filter, crash recovery, wrong-process)
- [x] SSE parser tests (single/multiple events, buffering, comment lines, line endings, Anthropic/OpenAI format)
- [x] StreamAccumulator tests (text accumulation, tool calls, to_message, JSON decode)
- [x] Echo stream tests (echo/static/stream/tool_call/error modes)
- [x] Anthropic stream tests (text streaming, tool use, auth error, HTTP error)
- [x] OpenAI stream tests (text streaming, tool calls, auth via 401, HTTP error)
- [x] Agent stream tests (basic streaming, status, concurrency rejection, persistence, iteration limit, error propagation, middleware hooks, Logger compat, telemetry, custom provider, ownership)
- [x] Agent stream integration tests (multi-turn tool loop, middleware event modification, Enumerable API, event suppression)
- [x] 793 total tests (88 new), 0 failures

---

## Phase 10: Top-Level API, Docs & Release ✅

Polish the public API surface, write documentation, build examples, and prepare for Hex.pm.

### Public API

- [x] `Agora.run/2` — one-shot: create agent, run task, return result (try/after cleanup)
- [x] `Agora.stream/2` — one-shot streaming variant (Stream.transform after_fun + monitor cleanup)
- [x] `Agora.start_agent/1`, `Agora.stop_agent/1` — long-lived agent management (covered by default args)
- [x] `Agora.run_workflow/1` — execute a workflow definition (covered by default args)
- [x] `@doc` and `@spec` on all provider `chat/2` and `stream_chat/2` implementations

### Documentation

- [x] Module-level `@moduledoc` for every public module (51 modules)
- [x] Getting Started guide (`guides/getting-started.md`)
- [x] Architecture overview with Mermaid supervision tree diagram (`guides/architecture.md`)
- [x] Provider setup guide — Anthropic, OpenAI, Echo, custom (`guides/providers.md`)
- [x] Tool authoring guide (`guides/tools.md`)
- [x] Middleware authoring guide (`guides/middleware.md`)
- [x] Orchestrator guide with examples (`guides/orchestration.md`)
- [x] Workflow engine guide (`guides/workflows.md`)

### Examples

- [x] `examples/simple_chat.exs` — single agent Q&A (Echo provider, `Agora.run/2`)
- [x] `examples/tool_use.exs` — agent with Calculator + DateTime tools (Echo `:function` mode)
- [x] `examples/streaming.exs` — streaming with explicit events (Echo `:stream` mode)
- [x] `examples/multi_agent.exs` — RoundRobin orchestration with termination conditions
- [x] `examples/workflow.exs` — DAG workflow with parallel fan-out (pure functions)

### Hex Release Prep

- [x] `mix.exs` — description, `package/0`, `docs/0`, source_url, module groups, guide extras
- [x] `CHANGELOG.md` — Keep a Changelog format, v0.1.0 entry
- [x] `LICENSE` — MIT (already present)
- [x] CI setup (`.github/workflows/ci.yml` — test + dialyzer jobs, caching)
- [ ] Publish to Hex.pm

### Testing

- [x] Convenience API tests (run/2 and stream/2 with cleanup verification)
- [x] 805 total tests (12 new), 0 failures

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
| Schema validation | Lightweight in-house | Covers practical subset (types, required, enum, nested); `ex_json_schema` overkill |
| ToolBroker | Stateless module | Tools come from AgentConfig, no GenServer registry needed |
| Broker return type | `{:ok, [ToolResult]}` always | Agent loop needs all results (successes and errors) to send back to LLM |
| Tool timeout | Deadline-based + brutal_kill | Per-tool timeouts enforced from spawn time; no grace period for exit-trapping tasks |
| Middleware model | Chain with `next` | Familiar (Plug-style), composable, supports halt semantics |
| Orchestrators | Separate from agents | Agents stay simple; coordination is a distinct concern |
| State model | Minimal enum | `:idle` / `:running` — synchronous `handle_call` means `:running` isn't externally observable; future phases (streaming, middleware) may expand |
| Agent crash handling | `try/catch` + `:unknown` error type | Catches raise/exit/throw; uses `:unknown` (not `:provider_error`) since crash source is ambiguous; metadata stringified for JSON safety |
| Agent concurrency | Queuing (GenServer default) | Concurrent `run/2` calls queue behind each other; simpler than async rejection; iteration limit bounds each run |
| Telemetry metadata | Sanitized (no config) | Only provider/model/agent_name/max_iterations emitted; `provider_opts` excluded to prevent API key leakage |
| Crash history | Process dictionary tracking | `reasoning_loop` stores latest messages in process dictionary each iteration; catch block recovers partial history instead of losing it |
| Memory | Behaviour + backends; canonical store | Swappable storage; Buffer for dev, File for persistence, extensible to ETS/DB. Memory is canonical — state.messages re-derived after each save |
| Memory save | Atomic `save/2` at run boundaries | Full list replacement eliminates partial persistence and diff bugs; single save per run |
| Memory errors | Fatal (override successful run) | Silent data loss worse than visible error; consistent with project error convention |
| Middleware entries | Modules or 2-arity closures | Chain dispatches on `is_atom` vs `is_function/2`; closures enable parameterized middleware via factory functions |
| Parameterized MW | Factory returns closure (`MaxTokens.new(opts)`) | Keeps behaviour at 2-arity; closures capture options naturally without complicating the interface |
| Middleware chain | Plug-style `next` composition | Familiar to Elixir developers, composable, natural halt semantics; alternatives (pipeline, event) rejected |
| Context hook field | 4 hook atoms | Middleware pattern-matches on `ctx.hook` to act at specific interception points |
| Halt reason | `{:halt, term()}` conventionally `%Error{}` | Agent wraps non-Error reasons via `wrap_halt_reason/1` for uniformity |
| Empty MW fast path | Skip context/chain when `config.middleware == []` | Zero overhead for agents without middleware; no Context struct allocation |
| Config mutable per-iter | Agent reads back `ctx.config` after `before_provider_call` | Matches TODO spec; modifications scoped to current iteration — not persisted to GenServer state |
| Metadata persistence | `state.middleware_metadata` carries metadata across loop iterations | Enables Timeout deadline to survive across iterations within a single `run/2` |
| Namespaced metadata | Each middleware uses its module as key (`ctx.metadata[Agora.Middleware.Timeout]`) | Prevents collisions between middleware sharing the metadata map |
| Chain error safety | try/catch wraps each invoke; invalid entries/crashes convert to `{:halt, %Error{type: :middleware_error}}` | Middleware bugs never crash the agent process — they produce typed, debuggable errors |
| Timeout cooperative | Checks deadline at hook points only; no mid-flight interruption | Hard wall-clock enforcement requires Task wrapping — significantly more complex; cooperative catches multi-iteration accumulation |
| Halt persistence | On halt, no new messages appended — `state.messages` unchanged | Clean rollback: halted iterations leave no trace in conversation history |
| Tool call filter sync | If `before_tool_call` filters calls, assistant message reflects only approved calls | Prevents tool_calls/results divergence in conversation history |

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
├── stream_event.ex                       # Phase 9
├── stream.ex                             # Phase 9
│
├── provider/
│   ├── provider.ex                    # Phase 1 (behaviour)
│   ├── echo.ex                        # Phase 1
│   ├── anthropic.ex                   # Phase 1
│   ├── openai.ex                      # Phase 1
│   ├── sse.ex                         # Phase 9
│   └── stream_accumulator.ex          # Phase 9
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
├── orchestrator.ex                      # Phase 5 (behaviour)
├── orchestrator/
│   ├── runner.ex                      # Phase 5
│   ├── runner_supervisor.ex           # Phase 5
│   ├── termination_condition.ex       # Phase 5
│   ├── single.ex                      # Phase 5
│   ├── round_robin.ex                 # Phase 5
│   ├── supervisor.ex                  # Phase 5 (delegation strategy)
│   └── chat_room.ex                   # Phase 5
│
├── memory.ex                             # Phase 6 (behaviour + dispatch)
├── memory/
│   ├── buffer.ex                      # Phase 6
│   └── file.ex                        # Phase 6
│
├── telemetry.ex                       # Phase 7
├── event_bus.ex                       # Phase 7
│
├── workflow.ex                        # Phase 8
└── workflow/
    ├── step.ex                        # Phase 8
    ├── edge.ex                        # Phase 8
    ├── executor.ex                    # Phase 8
    ├── builder.ex                     # Phase 8
    ├── checkpoint_store.ex            # Phase 8 (behaviour + dispatch)
    └── checkpoint_store/
        ├── memory.ex                  # Phase 8
        └── file.ex                    # Phase 8
```
