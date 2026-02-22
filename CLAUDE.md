# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
mix deps.get          # Install dependencies
mix compile           # Compile (add --warnings-as-errors for CI)
mix test              # Run all tests
mix test path/to/test.exs                  # Run single test file
mix test path/to/test.exs:42              # Run specific test at line
mix test --only describe:"function_name"  # Run tests matching describe
mix format            # Auto-format code
mix format --check-formatted              # Check formatting (CI)
mix dialyzer          # Static type analysis (slow first run, cached after)
```

## Architecture

Agora is a multi-agent runtime framework for Elixir. See `docs/internal/adr.md` for design decisions.

### Core Data Flow

```
AgentConfig → Provider.chat(messages, config) → {:ok, Message.t()} | {:error, Error.t()}
```

All LLM interaction flows through the `Agora.Provider` behaviour. Providers translate between Agora's internal message format and provider-specific API formats (Anthropic Messages API, OpenAI Chat Completions, Gemini API, Ollama Chat API).

### Public API

The primary public API is agent-first:

- **`Agora.agent/3`** — Define an agent configuration (returns `%AgentConfig{}`)
- **`Agora.run/2`** — One-shot single agent execution
- **`Agora.stream/2`** — One-shot streaming
- **`Agora.sequential/3`**, **`parallel/3`** — Deterministic agent composition (workflow substrate)
- **`Agora.round_robin/3`**, **`group_chat/3`**, **`supervisor/4`**, **`plan/4`**, **`handoff/3`** — Autonomous agent composition (orchestrator substrate)
- **`Agora.agent_tool/2`** — Wrap agent as tool for hierarchical nesting
- **`Agora.run_workflow/2`** — DAG execution for advanced Builder workflows
- **`Agora.start_agent/2`**, **`stop_agent/1`** — Low-level agent lifecycle
- **`Agora.start_runner/2`**, **`stop_runner/1`** — Low-level runner lifecycle (custom orchestrators)
- **`Agora.stream_run/2`** — Low-level stream on existing agent

### Key Modules

- **`Agora.Compose`** — All composition function implementations + validation
- **`Agora.AgentTool`** — Agent-as-tool wrapping with depth guard
- **`Agora.Provider`** — Behaviour defining `chat/2` callback + resolution (`resolve/1` maps atoms like `:anthropic` to modules). `get_provider_opt/3` implements two-tier config lookup: `provider_opts` first, then application config.
- **`Agora.Message`** — Universal message struct with role (`:system | :user | :assistant | :tool`), content, tool_calls, tool_results, metadata. Content is nilable for assistant messages that only contain tool calls.
- **`Agora.AgentConfig`** — NimbleOptions-validated configuration. `provider_opts` keyword list carries per-agent overrides (API keys, base URLs, `req_options` for test injection).
- **`Agora.Error`** — Typed errors returned as `{:error, %Error{}}` tuples (never raised). Types: `:provider_error`, `:tool_error`, `:validation_error`, `:timeout`, `:rate_limit`, `:auth_error`, `:config_error`, `:iteration_limit`, `:middleware_error`, `:memory_error`, `:orchestration_error`, `:workflow_error`, `:streaming_error`, `:cancelled`, `:unknown`.
- **`Agora.Config`** — Wraps `Application.get_env/3`. Convention: `api_key(:anthropic)` reads `:anthropic_api_key`.
- **`Agora.Execution`** — Internal execution facade for orchestrators and workflows (not public API).

### Provider Implementations

All providers follow the same pattern: `fetch_api_key → build_request_body → do_request → parse_response`.

- **Echo** (`Agora.Provider.Echo`) — 6 configurable modes for testing. No HTTP.
- **Anthropic** (`Agora.Provider.Anthropic`) — System messages extracted to top-level param. Adjacent same-role messages merged (Anthropic requires alternating roles). Tool results sent as `user` role with `tool_result` content blocks.
- **OpenAI** (`Agora.Provider.OpenAI`) — System messages stay inline. Tool arguments are JSON strings (encode on send, decode on receive with malformed fallback). One Agora `:tool` message with N results expands to N separate OpenAI `tool` messages.
- **Gemini** (`Agora.Provider.Gemini`) — System messages extracted to `systemInstruction`. Adjacent same-role messages merged (parts-based). API key as query param. Tool calls use positional correlation with synthetic `gemini_tc_N` IDs. Streaming via SSE.
- **Ollama** (`Agora.Provider.Ollama`) — System messages inline. Optional auth (no key required for local). Tool results use `tool_name` field (not `tool_call_id`). Synthetic `ollama_tc_N` IDs. Streaming via NDJSON. Default 120s timeout.

### HTTP Testing Pattern

Providers accept `req_options` in `provider_opts` for test injection via `Req.Test`:

```elixir
config = AgentConfig.new!(
  provider: :anthropic, model: "claude-sonnet-4-20250514",
  provider_opts: [api_key: "test-key", req_options: [plug: {Req.Test, __MODULE__}]]
)
# Then in test: Req.Test.stub(__MODULE__, fn conn -> ... end)
```

## Conventions

- **Error handling**: Always `{:ok, result} | {:error, %Agora.Error{}}` — no exceptions for control flow.
- **Constructors**: `new/1` returns `{:ok, struct}`, `new!/1` raises. Structs use `@derive Jason.Encoder`.
- **Tests**: Default `async: true`. Tests that mutate `Application` env use `async: false` in separate modules (e.g., `*_config_test.exs`). Mirror source structure under `test/agora/`. Organized into `describe` blocks per function.
- **Config**: Runtime API keys via environment variables in `config/runtime.exs`. Provider-specific keys follow the `<provider>_api_key` naming convention.
- **Composition API**: All composition functions accept keyword lists of `{atom, AgentConfig.t()}`. Validation via `Compose.validate_agents/1`.

## Current Status

Phases 0–10 complete plus agent-first refocusing.

### Composition API

- `Agora.Compose` — 7 composition functions: `sequential/3`, `parallel/3`, `round_robin/3`, `group_chat/3`, `supervisor/4`, `plan/4`, `handoff/3`
- Workflow-backed patterns (sequential, parallel) compile to `Execution.run_workflow/3`
- Orchestrator-backed patterns compile to `Execution.run/3`
- Shared agent reference model: keyword list `[{atom, AgentConfig.t()}]`
- `validate_agents/1` checks: keyword list, non-empty, no duplicate keys, all AgentConfig values
- Cross-cutting opts (cancel_token, context_policy, telemetry_metadata) pass through to substrate

### Agent-as-Tool

- `Agora.AgentTool.new/2` creates `%FunctionTool{}` wrapping `Agora.run/2`
- Depth guard via `provider_opts: [_agora_tool_depth: n]` propagated through tool context
- Default max_depth: 3, default timeout: 300_000ms
- Tool context wiring: `build_tool_context/1` in loop.ex and stream_loop.ex

### Workflow AgentStep

- `Agora.Workflow.AgentStep.spec/3` creates step spec tuples for Builder/Patterns
- `Builder.step/2` accepts pre-built tuples from `AgentStep.spec/3`

### Top-Level API & Release (Phase 10)

- `Agora.run/2` — one-shot agent: start, run, cleanup via `try/after`
- `Agora.stream/2` — one-shot streaming: `Stream.transform` `after_fun` + spawn monitor for caller crash cleanup
- `mix.exs` — `package/0`, `docs/0` with module groups and guide extras for HexDocs
- 9 guides under `guides/` (getting-started, agents, composition, architecture, providers, tools, middleware, orchestration, workflows)

### Memory System (Phase 6)

- `Agora.Memory` behaviour: `init/1`, `get/1`, `save/2`, `clear/1` — dispatch via `{module, state}` tuples
- Two backends: `Buffer` (in-memory ring buffer with `:queue`) and `File` (JSON with atomic writes)
- Memory is the canonical message store — `state.messages` re-derived from `Memory.get()` after each run

### Observability (Phase 7)

- `Agora.Telemetry` — helper module with `span/3` and `emit/3` wrappers; canonical event documentation in `@moduledoc`
- `Agora.EventBus` — Registry-backed pub/sub: `subscribe/2`, `broadcast/2`, `unsubscribe/1`

### Workflow Engine (Phase 8)

- `Agora.Workflow.Builder` — DSL for constructing DAG workflows
- `Agora.Workflow.Executor` — Stateless DAG executor with topological sort, parallel fan-out
- Step handlers: 1-arity functions or `AgentConfig` structs
- `Agora.run_workflow/2` convenience function

### Streaming Support (Phase 9)

- `Agora.StreamEvent` — struct with 7 typed constructors
- `Agora.Stream` — Enumerable wrapper; ownership enforced; guaranteed terminal signal
- `Agora.Provider.SSE` — shared SSE line parser
- Telemetry: `[:agora, :provider, :stream, :start | :stop]` and `[:agora, :agent, :stream_run, :start | :stop]`
