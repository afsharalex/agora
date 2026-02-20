# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-02-20

### Added

- **Provider Abstraction** -- Unified `Agora.Provider` behaviour with Anthropic, OpenAI, and Echo implementations. Two-tier config resolution (per-agent `provider_opts` then application config).
- **Agent Runtime** -- `Agora.Agent` GenServer with reasoning loop (provider call, tool execution, repeat). Supervised via `Agora.Agent.Supervisor` DynamicSupervisor. Crash protection via try/catch.
- **Tool System** -- `Agora.Tool` behaviour, `FunctionTool` adapter for inline definitions, `Agora.Tool.Schema` JSON Schema helpers, `Agora.ToolBroker` supervised parallel execution with deadline-based timeouts. Built-in Calculator and DateTime tools.
- **Middleware System** -- Plug-style composable interceptors with 5 hooks (before/after provider call, before/after tool call, on stream event). Built-in: Logger, MaxTokens, Timeout, ToolApproval.
- **Orchestration** -- `Agora.Orchestrator` behaviour with Runner GenServer. Built-in strategies: Single, RoundRobin, Supervisor (delegation), ChatRoom (shared transcript). Composable `TerminationCondition` closures.
- **Memory System** -- `Agora.Memory` behaviour with Buffer (in-memory ring buffer) and File (JSON persistence with atomic writes) backends. Memory as canonical message store.
- **Observability** -- `Agora.Telemetry` helpers with 28 events across 11 prefixes. `Agora.EventBus` Registry-backed pub/sub for internal messaging.
- **Workflow Engine** -- DAG-based `Agora.Workflow.Executor` with topological sort, parallel fan-out, conditional edges, retry, deadline timeouts, and checkpoint persistence. `Agora.Workflow.Builder` DSL.
- **Streaming Support** -- Real-time token streaming via `Agora.Agent.stream_run/2` with `Agora.Stream` Enumerable wrapper. `Agora.StreamEvent` typed events. Provider SSE parsing. Multi-turn tool execution during streaming.
- **Convenience API** -- `Agora.run/2` one-shot agent execution, `Agora.stream/2` one-shot streaming with automatic cleanup.
- **Structured Errors** -- `Agora.Error` with 14 typed error categories, consistent `{:ok, result} | {:error, %Error{}}` throughout.
- **Configuration** -- `Agora.AgentConfig` with NimbleOptions validation. `Agora.Config` application-level helpers.
