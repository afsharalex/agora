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

Agora is a multi-agent runtime framework for Elixir. It follows a phased implementation plan (`TODO.md`) building toward orchestrated AI agents on the BEAM.

### Core Data Flow

```
AgentConfig → Provider.chat(messages, config) → {:ok, Message.t()} | {:error, Error.t()}
```

All LLM interaction flows through the `Agora.Provider` behaviour. Providers translate between Agora's internal message format and provider-specific API formats (Anthropic Messages API, OpenAI Chat Completions).

### Key Modules

- **`Agora.Provider`** — Behaviour defining `chat/2` callback + resolution (`resolve/1` maps atoms like `:anthropic` to modules). `get_provider_opt/3` implements two-tier config lookup: `provider_opts` first, then application config.
- **`Agora.Message`** — Universal message struct with role (`:system | :user | :assistant | :tool`), content, tool_calls, tool_results, metadata. Content is nilable for assistant messages that only contain tool calls.
- **`Agora.AgentConfig`** — NimbleOptions-validated configuration. `provider_opts` keyword list carries per-agent overrides (API keys, base URLs, `req_options` for test injection).
- **`Agora.Error`** — Typed errors returned as `{:error, %Error{}}` tuples (never raised). Types: `:provider_error`, `:tool_error`, `:validation_error`, `:timeout`, `:rate_limit`, `:auth_error`, `:config_error`, `:iteration_limit`, `:middleware_error`, `:memory_error`, `:orchestration_error`, `:workflow_error`, `:streaming_error`, `:unknown`.
- **`Agora.Config`** — Wraps `Application.get_env/3`. Convention: `api_key(:anthropic)` reads `:anthropic_api_key`.

### Provider Implementations

All providers follow the same pattern: `fetch_api_key → build_request_body → do_request → parse_response`.

- **Echo** (`Agora.Provider.Echo`) — 6 configurable modes for testing. No HTTP.
- **Anthropic** (`Agora.Provider.Anthropic`) — System messages extracted to top-level param. Adjacent same-role messages merged (Anthropic requires alternating roles). Tool results sent as `user` role with `tool_result` content blocks.
- **OpenAI** (`Agora.Provider.OpenAI`) — System messages stay inline. Tool arguments are JSON strings (encode on send, decode on receive with malformed fallback). One Agora `:tool` message with N results expands to N separate OpenAI `tool` messages.

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

## Current Status

Phases 0–10 complete. See `TODO.md` for the full 10-phase roadmap and `docs/Design-v0.md` for architecture principles.

### Top-Level API & Release (Phase 10)

- `Agora.run/2` — one-shot agent: start, run, cleanup via `try/after`
- `Agora.stream/2` — one-shot streaming: `Stream.transform` `after_fun` + spawn monitor for caller crash cleanup
- `mix.exs` — `package/0`, `docs/0` with module groups and guide extras for HexDocs
- `.github/workflows/ci.yml` — test + dialyzer jobs with deps/build/PLT caching
- 7 guides under `guides/` (getting-started, architecture, providers, tools, middleware, orchestration, workflows)
- 5 examples under `examples/` — all use Echo provider (no API key needed)
- `CHANGELOG.md` — Keep a Changelog format, single v0.1.0 entry

### Memory System (Phase 6)

- `Agora.Memory` behaviour: `init/1`, `get/1`, `save/2`, `clear/1` — dispatch via `{module, state}` tuples
- Two backends: `Buffer` (in-memory ring buffer with `:queue`) and `File` (JSON with atomic writes)
- Memory is the canonical message store — `state.messages` re-derived from `Memory.get()` after each run
- Config format: `{module, keyword()}` tuple (e.g. `{Agora.Memory.Buffer, max_messages: 100}`)
- Save at run boundaries (after reasoning loop, before telemetry) — fatal on failure
- `Agent.clear_memory/1` API; `:transient` restart when memory configured
- Module validation via `Code.ensure_loaded/1` + `function_exported?/3` at init

### Observability (Phase 7)

- `Agora.Telemetry` — helper module with `span/3` and `emit/3` wrappers; canonical event documentation in `@moduledoc`
- Provider telemetry: `Provider.chat/3` emits `[:agora, :provider, :call, :start | :stop | :exception]` via span
- Tool telemetry: outer `start`/`stop` in `ToolBroker.execute/4` (guaranteed terminal event), inner `:exception` in `execute_single/4` catch
- Middleware telemetry: `Chain.run/2` emits `[:agora, :middleware, :call, :start | :stop]` via span; empty list fast path skips telemetry
- Agent exception: `[:agora, :agent, :run, :exception]` emitted in `safe_reasoning_loop` catch with sanitized metadata
- `Agora.EventBus` — Registry-backed pub/sub: `subscribe/2`, `broadcast/2`, `unsubscribe/1`; idempotent subscribe; NOT wired to telemetry
- Existing Agent/Orchestrator telemetry unchanged (manual `:telemetry.execute`); new instrumentation uses `:telemetry.span/3`

### Workflow Engine (Phase 8)

- `Agora.Workflow.Builder` — DSL for constructing DAG workflows: `step/3`, `edge/3`, `sequence/2`, `parallel/2`, `build/1`
- `Agora.Workflow.Executor` — stateless DAG executor with topological sort, parallel fan-out via `Task.Supervisor`
- Step handlers: 1-arity functions or `AgentConfig` structs. `input_mapper` controls AgentConfig message construction.
- Step `inputs` drives auto-edge generation; `outputs` is documentation only
- Result contract: `{:ok, value} | {:error, Error.t()} | :skipped`
- Conditional edges: 1-arity functions with explicit resolution matrix (satisfied/not_required/failed_dep/pending)
- Failure modes: `:abort` (default, fail fast) or `:skip` (continue past failures)
- Deadline-based timeout (ToolBroker pattern); per-step retry count
- `Agora.Workflow.CheckpointStore` behaviour + dispatch: `Memory` and `File` backends
- Checkpoint key mapping: backends return native keys, dispatch maps string→atom via known step IDs
- Telemetry: `[:agora, :workflow, :run]` and `[:agora, :workflow, :step]` events via `span/3`
- `Agora.run_workflow/2` convenience function

### Streaming Support (Phase 9)

- `Agora.Provider` extended with optional `stream_chat/2` callback — backward compatible (providers with only `chat/2` still work)
- `Agora.StreamEvent` — struct with 7 typed constructors: `:text_delta`, `:tool_call_start`, `:tool_call_delta`, `:tool_result`, `:message_complete`, `:done`, `:error`
- `Agora.Stream` — Enumerable wrapper; ownership enforced (only caller can enumerate); guaranteed terminal signal
- `Agora.Provider.SSE` — shared SSE line parser with partial-data buffering for both Anthropic and OpenAI
- `Agora.Provider.StreamAccumulator` — accumulates text/tool_call deltas into final `Message`
- Agent status: `:idle | :running | :streaming`; concurrent `run/2` or `stream_run/2` rejected while streaming
- Streaming reasoning loop: relay events through `:on_stream_event` middleware, multi-turn tool execution
- New middleware hook `:on_stream_event` for per-event interception; middleware can suppress events via `ctx.stream_event = nil`
- Echo provider `stream_chat/2`: modes `:echo`, `:static`, `:stream` (explicit events/function/delay), `:function`, `:tool_call`, `:error`
- Telemetry: `[:agora, :provider, :stream, :start | :stop]` and `[:agora, :agent, :stream_run, :start | :stop]` (emit-based, not span)
- `Agora.StreamSupervisor` (Task.Supervisor) for streaming task lifecycle
- Memory save after stream completes — failure logged + telemetry, agent transitions to `:idle` regardless
- `Agora.stream_run/2` convenience function delegates to `Agent.stream_run/2`
