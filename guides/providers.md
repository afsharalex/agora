# Providers

How to configure built-in providers and implement custom ones.

## Built-in Providers

| Provider | Module | API |
|----------|--------|-----|
| Anthropic | `Agora.Provider.Anthropic` | Messages API |
| OpenAI | `Agora.Provider.OpenAI` | Chat Completions API |
| Echo | `Agora.Provider.Echo` | No HTTP (testing) |

## Set Up Anthropic

```elixir
# Via environment variable
export ANTHROPIC_API_KEY="sk-ant-..."

# Or in config/runtime.exs
config :agora, anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")

# Create a config
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  instructions: "You are a helpful assistant."
)
```

### Per-agent overrides

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  provider_opts: [
    api_key: "sk-ant-different-key",
    base_url: "https://my-proxy.example.com",
    timeout: 60_000,
    max_tokens: 8192
  ]
)
```

## Set Up OpenAI

```elixir
export OPENAI_API_KEY="sk-..."

config = Agora.AgentConfig.new!(
  provider: :openai,
  model: "gpt-4o",
  instructions: "You are a helpful assistant."
)
```

## Use Echo for Testing

The Echo provider requires no API key and returns predictable responses:

```elixir
# Default :echo mode -- echoes last user message
config = Agora.AgentConfig.new!(provider: :echo, model: "echo")

# :static mode -- fixed response
config = Agora.AgentConfig.new!(
  provider: :echo, model: "echo",
  provider_opts: [echo_mode: :static, echo_response: "Hello!"]
)

# :function mode -- custom logic
config = Agora.AgentConfig.new!(
  provider: :echo, model: "echo",
  provider_opts: [
    echo_mode: :function,
    echo_function: fn messages, _config ->
      {:ok, Agora.Message.assistant("Custom response")}
    end
  ]
)

# :error mode -- simulate failures
config = Agora.AgentConfig.new!(
  provider: :echo, model: "echo",
  provider_opts: [
    echo_mode: :error,
    echo_error_type: :rate_limit,
    echo_error_message: "Too many requests"
  ]
)
```

### Echo modes

| Mode | Description | Config keys |
|------|-------------|-------------|
| `:echo` | Echoes last user message | (default) |
| `:static` | Fixed response | `echo_response` |
| `:tool_call` | Returns tool calls | `echo_tool_calls` |
| `:sequence` | Cycles through responses | `echo_responses` |
| `:error` | Returns an error | `echo_error_type`, `echo_error_message` |
| `:function` | Custom 2-arity function | `echo_function` |

## Implement a Custom Provider

Create a module implementing the `Agora.Provider` behaviour:

```elixir
defmodule MyApp.Provider.Custom do
  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Error, Message}

  @impl true
  def chat(messages, %AgentConfig{} = config) do
    # 1. Build request from messages and config
    # 2. Make HTTP call
    # 3. Parse response into Message
    {:ok, Message.assistant("Response from custom provider")}
  end

  # Optional: implement stream_chat/2 for streaming support
  # @impl true
  # def stream_chat(messages, %AgentConfig{} = config) do
  #   ...
  # end
end
```

Register it in your config:

```elixir
config = Agora.AgentConfig.new!(
  provider: MyApp.Provider.Custom,
  model: "my-model"
)
```

## Direct Provider Calls

For one-off calls without the agent reasoning loop:

```elixir
alias Agora.{AgentConfig, Message, Provider}

config = AgentConfig.new!(provider: :anthropic, model: "claude-sonnet-4-20250514")
{:ok, response} = Provider.chat(:anthropic, [Message.user("Hello!")], config)
```

## HTTP Testing with Req.Test

Inject mock HTTP responses in tests:

```elixir
config = AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  provider_opts: [
    api_key: "test-key",
    req_options: [plug: {Req.Test, MyTest}]
  ]
)

Req.Test.stub(MyTest, fn conn ->
  Req.Test.json(conn, %{
    "content" => [%{"type" => "text", "text" => "Mocked response"}],
    "role" => "assistant",
    "stop_reason" => "end_turn"
  })
end)
```
