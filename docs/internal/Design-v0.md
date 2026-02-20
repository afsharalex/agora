Agora — Framework Summary

What Agora is

Agora is a multi-agent runtime framework for Elixir that enables users to create collaborative AI agents using the BEAM actor model.

The core idea:

👉 Agents are processes that operate inside a shared “Agora” (space), where coordination, tool use, and orchestration patterns emerge through structured messaging and orchestration strategies.

The framework focuses on:
	•	simplicity of agent setup
	•	strong runtime guarantees (OTP supervision, concurrency)
	•	provider/tool abstraction
	•	flexible orchestration patterns (workflow and autonomous)

⸻

Core Design Principles

1) Simple Agent Definition (picoagents-inspired)

Users define agents declaratively:
	•	provider + model
	•	instructions/system prompt
	•	tools
	•	memory (optional)
	•	middleware/policies

Users should not need to understand OTP, GenServers, or state machines.

Example mental model:

“Create agents like objects; runtime handles execution.”

⸻

2) One Default Agent Loop

Agora provides a built-in reasoning/action loop:
	1.	Receive task/event
	2.	Build context
	3.	Call provider
	4.	Detect tool calls from model output
	5.	Execute tools
	6.	Add results to context
	7.	Repeat until termination

This mirrors picoagents:

👉 behavior is implicit in the loop, not exposed as “strategy” or “decider”.

⸻

3) Middleware as Primary Extension Mechanism

Rather than user-defined control flow, Agora uses middleware/interceptors.

Middleware can:
	•	approve or block tool calls
	•	enforce budgets (tokens/time/cost)
	•	inject prompts or context
	•	modify provider requests/responses
	•	log or observe events
	•	pause execution (human approval)
	•	enforce structured output

This allows behavior customization without modifying the core loop.

⸻

4) Orchestrators Define Multi-Agent Patterns

Agents remain mostly identical.

Orchestrators control:
	•	which agent runs next
	•	message routing
	•	shared context
	•	termination conditions

Examples:
	•	round-robin
	•	supervisor agent
	•	chat-room collaboration
	•	workflow execution (sequential/parallel/DAG)
	•	emergent autonomous coordination

Key idea:

👉 coordination is separate from agent behavior.

⸻

5) Minimal Runtime State Model

Avoid complex agent states.

Runtime phases limited to:
	•	idle
	•	awaiting provider response (streaming/non-streaming)
	•	awaiting tool result(s)
	•	awaiting approval

All cognitive flow lives in context/memory, not OTP states.

⸻

6) Tool Execution Architecture

Tool calls are first-class effects.

Flow:
	1.	Model requests tool
	2.	Agent runtime emits tool request
	3.	ToolBroker validates permissions
	4.	Tool executes asynchronously (Task.Supervisor)
	5.	Result returns to agent
	6.	Agent loop resumes

Supports:
	•	single tool calls
	•	parallel tool fan-out
	•	approval gating
	•	sandboxing

⸻

7) Provider Abstraction Layer

Unified provider interface:
	•	OpenAI
	•	Anthropic
	•	Gemini
	•	local models (Ollama etc.)
	•	future providers

Normalize differences:
	•	message formats
	•	tool calling formats
	•	streaming APIs
	•	structured outputs

Agents specify provider/model directly.

⸻

8) Workflow + Autonomous Modes (First-Class)

Agora supports two execution paradigms:

Workflow Mode

Explicit structure:
	•	sequential steps
	•	parallel fan-out
	•	DAG execution
	•	deterministic scheduling

Autonomous Mode

Emergent coordination:
	•	round robin
	•	supervisor agent
	•	chat-style collaboration
	•	dynamic delegation

These are runtime orchestrator strategies.

⸻

9) BEAM-Native Concurrency

Agora leverages OTP:
	•	Agents = supervised processes
	•	Tool execution = supervised tasks
	•	Orchestrators = processes
	•	Per-run supervision trees
	•	Fault tolerance and restartability

⸻

10) Observability + Approval UX (Design Goal)

Events are first-class:
	•	tool calls
	•	provider calls
	•	approvals
	•	messages
	•	state transitions

Designed for:
	•	UI integration
	•	audit trails
	•	debugging multi-agent systems

⸻

Key Components

Agent

Configuration + runtime process with default reasoning loop.

ToolBroker

Centralized execution + permissions + sandboxing.

ProviderGateway

Unified LLM interface.

Orchestrator

Defines coordination pattern.

Middleware Chain

Interception layer for behavior customization.

Event Bus / Router

Internal messaging between components.

⸻

Non-Goals (for initial version)
	•	No user-defined OTP state machines
	•	No explicit “strategy/decider” API
	•	No heavy DSL requirements
	•	Avoid over-engineered agent abstractions early

⸻

Why This Architecture Works

It combines:
	•	picoagents simplicity
	•	Elixir reliability
	•	extensibility without exposing complexity

Users interact with:
	•	agents
	•	tools
	•	orchestrators
	•	middleware

Everything else stays internal.
