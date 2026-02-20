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
- **`Agora.Error`** — Typed errors returned as `{:error, %Error{}}` tuples (never raised). Types: `:provider_error`, `:tool_error`, `:validation_error`, `:timeout`, `:rate_limit`, `:auth_error`, `:config_error`, `:iteration_limit`, `:middleware_error`, `:memory_error`, `:orchestration_error`, `:unknown`.
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

Phases 0–7 (Foundation, Provider Abstraction, Tool System, Agent Runtime, Middleware System, Orchestration, Memory System, Observability) are complete. Next up: Phase 8 (Workflow Engine) — see `TODO.md` for the full 10-phase roadmap and `docs/Design-v0.md` for architecture principles.

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
