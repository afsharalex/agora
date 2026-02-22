# Getting Started

This tutorial walks you through installing Agora, defining agents, composing them, and running your first multi-agent workflow.

## Prerequisites

- Elixir 1.19+ and Erlang/OTP 27+
- An API key from [Anthropic](https://console.anthropic.com/), [OpenAI](https://platform.openai.com/), or [Google AI Studio](https://aistudio.google.com/) (optional -- the Echo provider and local [Ollama](https://ollama.com/) work without one)

## Installation

Add Agora to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:agora, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Configure API Keys

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

## Define an Agent

Use `Agora.agent/3` to define an agent configuration:

```elixir
assistant = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant."
)
```

This returns an `%AgentConfig{}` struct. No process is started yet.

## Run a Single Agent

`Agora.run/2` creates a temporary agent, sends a message, and returns the response:

```elixir
{:ok, response} = Agora.run(assistant, "What is Elixir?")
IO.puts(response.content)
```

The agent is automatically cleaned up after the call.

## Try Without an API Key

Use the Echo provider for testing -- no HTTP calls, no API key:

```elixir
assistant = Agora.agent(:echo, "echo")

{:ok, response} = Agora.run(assistant, "Hello!")
IO.puts(response.content)
# => "Echo: Hello!"
```

## Compose Agents

The real power of Agora is composing multiple agents. Define a team and run them as a pipeline:

```elixir
researcher = Agora.agent(:echo, "echo",
  name: "researcher",
  instructions: "You are a research analyst."
)

writer = Agora.agent(:echo, "echo",
  name: "writer",
  instructions: "You are a technical writer."
)

{:ok, results} = Agora.sequential("Write about the BEAM VM", [
  researcher: researcher,
  writer: writer
])

Enum.each(results, fn {agent, {:ok, msg}} ->
  IO.puts("[#{agent}] #{msg.content}")
end)
```

## Agent-as-Tool

Wrap an agent as a tool for hierarchical composition:

```elixir
research_tool = Agora.agent_tool(researcher,
  name: "research_agent",
  description: "Delegates research to a specialist."
)

supervisor = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  instructions: "Use research_agent when you need research.",
  tools: [research_tool]
)

{:ok, response} = Agora.run(supervisor, "Research BEAM concurrency")
```

## Streaming

Stream tokens as they're generated instead of waiting for the complete response:

```elixir
config = Agora.agent(:anthropic, "claude-sonnet-4-20250514")

{:ok, stream} = Agora.stream(config, "Tell me a story")

stream
|> Stream.filter(&(&1.type == :text_delta))
|> Enum.each(fn event -> IO.write(event.data.text) end)
```

## Adding Tools

Give agents the ability to call functions:

```elixir
config = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
  tools: [Agora.Tool.Calculator]
)

{:ok, response} = Agora.run(config, "What is 42 * 17?")
# Agent calls Calculator, feeds result back to LLM, returns final answer
```

## Next Steps

- [Agents](agents.md) -- Agent lifecycle, memory, middleware
- [Composition](composition.md) -- All coordination patterns and the decision framework
- [Providers](providers.md) -- Configure Anthropic, OpenAI, Gemini, Ollama, or build a custom provider
- [Tools](tools.md) -- Create custom tools for your agents
- [Middleware](middleware.md) -- Add logging, timeouts, and token budgets
- [Orchestration](orchestration.md) -- Custom orchestrators and termination conditions
- [Workflows](workflows.md) -- Builder API, DAG topologies, and checkpoint persistence
- [Architecture](architecture.md) -- Understand Agora's design
