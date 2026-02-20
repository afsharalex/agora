# AGENTS.md

Guidance for coding agents working in this repository.

## Scope

- This project is an Elixir library (`:agora`) targeting Elixir `~> 1.19`.
- Phases 0-10 are complete; current focus is stabilization, docs quality, and release readiness.
- Architecture references live in `TODO.md`, `CLAUDE.md`, and `docs/Design-v0.md`.

## Current Status

- Core runtime is complete: providers, tools, agent runtime, middleware, orchestration, memory, observability, workflows, and streaming.
- Top-level convenience API is available:
  - `Agora.run/2` (one-shot run)
  - `Agora.stream/2` (one-shot streaming with cleanup)
  - `Agora.start_agent/1,2` / `Agora.stop_agent/1`
  - `Agora.run_workflow/1,2`
- Phase 10 deliverables are present:
  - `guides/*.md` (7 guides)
  - `examples/*.exs` (5 runnable examples)
  - `CHANGELOG.md`
  - `.github/workflows/ci.yml`
  - Hex metadata + ExDoc grouping in `mix.exs`

## Rules Files Check

- `.cursorrules`: not present.
- `.cursor/rules/`: not present.
- `.github/copilot-instructions.md`: not present.
- `CLAUDE.md` exists and is currently the main agent guidance file.

## Project Layout

- `lib/agora/*.ex`: core types/config (`AgentConfig`, `Message`, `Error`, etc.).
- `lib/agora/provider/*.ex`: provider implementations (`Echo`, `Anthropic`, `OpenAI`).
- `test/agora/**/*.exs`: unit tests mirroring source module structure.
- `config/config.exs`: default app config values.
- `config/runtime.exs`: runtime API key wiring from environment variables.
- `examples/*.exs`: runnable end-to-end examples (one-shot, tools, streaming, orchestration, workflow).
- `guides/*.md`: user-facing guides used in ExDoc extras.
- `.github/workflows/ci.yml`: CI for compile, format check, tests, and dialyzer.
- `CHANGELOG.md`: Keep a Changelog formatted release notes.

## Build, Lint, and Test Commands

```bash
mix deps.get
mix compile
mix compile --warnings-as-errors
mix test
mix test test/agora/provider/openai_test.exs
mix test test/agora/provider/openai_test.exs:125
mix test --only describe:"tool use response"
mix format
mix format --check-formatted
mix dialyzer
mix docs
mix hex.build
mix run examples/workflow.exs
```

## Test Command Notes

- Single file: `mix test path/to/file_test.exs`.
- Single test by line: `mix test path/to/file_test.exs:LINE`.
- Single `describe` block: `mix test --only describe:"name"`.
- This repo heavily uses `describe` blocks named after function arity (e.g. `"new/1"`).
- Most tests are `async: true`; config-oriented tests may be synchronous.
- Convenience API cleanup tests should run `async: false` when asserting supervisor child counts.

## Coding Style: Module Structure

- Use `defmodule Agora.*` namespace consistently.
- Keep public API near top-level functions, private helpers below.
- Prefer focused modules with one clear responsibility.
- For providers, follow existing pipeline pattern: `fetch_api_key -> build_request_body -> do_request -> parse_response`.

## Imports, Aliases, and Requires

- Prefer `alias Agora.{...}` grouped aliases at top of module.
- Avoid broad `import` unless it materially improves readability.
- Keep alias list short and relevant to the module.
- In tests, alias module under test + related structs explicitly.

## Formatting Conventions

- Use default `mix format` output; do not hand-format against it.
- Formatter inputs include `mix.exs`, `.formatter.exs`, and all `config/lib/test` `.ex/.exs` files.
- Use trailing commas in multiline literals (formatter will enforce).
- Keep pattern matches and long assertions readable across multiple lines.

## Types, Specs, and Structs

- Define `@type t :: %__MODULE__{...}` for structs.
- Add `@type` enums for constrained atoms (roles, status, error types).
- Add `@spec` for all public functions.
- Keep struct defaults explicit in `defstruct`.
- Core structs derive JSON encoding (`@derive Jason.Encoder`).

## Naming Conventions

- Modules: `Agora.Foo`, `Agora.Provider.Bar`.
- Functions/vars: `snake_case`.
- Predicate-like helpers: readable boolean guards (`is_binary`, `is_list`, etc.).
- Constructor pattern:
  - `new/1` (or `new/arity`) returns `{:ok, t()} | {:error, Agora.Error.t()}` when validation can fail.
  - `new!/1` raises on invalid input.

## Error Handling Conventions

- Prefer explicit tuples over exceptions for control flow.
- Canonical shape: `{:ok, value} | {:error, %Agora.Error{}}`.
- Use `Agora.Error.wrap/3` for fast error tuple creation.
- Reserve raising for bang functions (`new!`, `fetch!`) and truly exceptional boundaries.
- Map remote HTTP failures to typed internal errors (`:auth_error`, `:rate_limit`, etc.).

## Data and JSON Translation Conventions

- Internal structs use atom keys and typed fields.
- External provider payloads use string keys.
- Keep translation logic explicit and provider-specific.
- OpenAI tool arguments: encode maps to JSON strings on send; decode on receive.
- Anthropic system handling: extract/compose system text at top-level request field.

## Configuration Conventions

- Application config is read through `Agora.Config` helpers.
- Provider options should resolve in this order:
  1. `AgentConfig.provider_opts`
  2. app config (`Application.get_env(:agora, ...)` via `Agora.Config`)
- Runtime API key env vars currently recognized:
  - `ANTHROPIC_API_KEY`
  - `OPENAI_API_KEY`
  - `GOOGLE_API_KEY`

## Documentation Conventions

- When adding/changing public API, update docs in the same change:
  - `@doc`/`@spec` on public functions
  - `README.md` quick-start usage where relevant
  - relevant guide(s) in `guides/`
  - ExDoc config in `mix.exs` if adding/removing guide pages
- Keep examples runnable with `mix run examples/<name>.exs` and prefer Echo-based defaults for no-key local verification.

## Testing Conventions

- Use `ExUnit.Case, async: true` unless mutating global app state.
- Organize tests by function in `describe "function/arity"` blocks.
- Keep assertion style direct and specific.
- For provider HTTP tests, inject `Req.Test` via `provider_opts[:req_options]`.
- Common provider test shape:
  - Build config helper
  - Stub HTTP with `Req.Test.stub/2`
  - Assert request translation and response parsing
  - Assert typed error mapping paths

## Change Discipline for Agents

- Make minimal, targeted edits; preserve existing style and naming.
- Do not introduce new dependencies without strong justification.
- Do not rewrite architecture opportunistically; follow established decisions documented in `TODO.md` and `docs/Design-v0.md`.
- When adding new modules, mirror existing test layout under `test/agora/...`.
- If adding public API, add tests + specs + docs in the same change.

## Quick Pre-PR Checklist

- Code formatted with `mix format`.
- Tests pass (`mix test`, plus focused single-file tests while iterating).
- No compile warnings (`mix compile --warnings-as-errors`).
- New behavior covered by tests (success + failure paths).
- Error tuple contract preserved.
- Docs build cleanly (`mix docs`) when touching docs/public API.
- Package still builds (`mix hex.build`) when touching `mix.exs` metadata/docs/package files.
