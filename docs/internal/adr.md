# Architecture Decision Records

Design decisions, dependency choices, and target file layout for the Agora project.
Extracted from the original `TODO.md` roadmap after all 10 phases were completed.

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
