# Getting Started

This tutorial walks you through installing Agora, configuring a provider, and running your first agent.

## Prerequisites

- Elixir 1.19+ and Erlang/OTP 27+
- An API key from [Anthropic](https://console.anthropic.com/) or [OpenAI](https://platform.openai.com/) (optional -- the Echo provider works without one)

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

## Your First Agent

The simplest way to run an agent is `Agora.run/2` -- it creates a temporary agent, sends a message, and returns the response:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant."
)

{:ok, response} = Agora.run(config, "What is Elixir?")
IO.puts(response.content)
```

The agent is automatically cleaned up after the call.

## Try Without an API Key

Use the Echo provider for testing -- no HTTP calls, no API key:

```elixir
config = Agora.AgentConfig.new!(
  provider: :echo,
  model: "echo"
)

{:ok, response} = Agora.run(config, "Hello!")
IO.puts(response.content)
# => "Echo: Hello!"
```

## Long-Lived Agents

For multi-turn conversations, start a supervised agent process:

```elixir
alias Agora.{AgentConfig, Agent}

config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant."
)

{:ok, pid} = Agora.start_agent(config)

{:ok, r1} = Agent.run(pid, "My name is Alice.")
{:ok, r2} = Agent.run(pid, "What is my name?")
# The agent remembers the conversation

Agora.stop_agent(pid)
```

## Streaming

Stream tokens as they're generated instead of waiting for the complete response:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514"
)

{:ok, stream} = Agora.stream(config, "Tell me a story")

stream
|> Stream.filter(&(&1.type == :text_delta))
|> Enum.each(fn event -> IO.write(event.data.text) end)
```

## Adding Tools

Give agents the ability to call functions:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  tools: [Agora.Tool.Calculator]
)

{:ok, response} = Agora.run(config, "What is 42 * 17?")
# Agent calls Calculator, feeds result back to LLM, returns final answer
```

## Next Steps

- [Providers](providers.md) -- Configure Anthropic, OpenAI, or build a custom provider
- [Tools](tools.md) -- Create custom tools for your agents
- [Middleware](middleware.md) -- Add logging, timeouts, and token budgets
- [Execution Modes](execution-modes.md) -- Unified `run_mode/3` API for orchestration and workflows
- [Orchestration](orchestration.md) -- Custom orchestrators and termination conditions
- [Workflows](workflows.md) -- Builder API, DSLs, and checkpoint persistence
- [Architecture](architecture.md) -- Understand Agora's design
