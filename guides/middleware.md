# Middleware

How to use built-in middleware and write custom interceptors.

## Overview

Middleware are composable interceptors that hook into the agent reasoning loop at 5 points. They can inspect, modify, or halt the execution at each hook.

## Hook Points

| Hook | When | Can modify |
|------|------|------------|
| `:before_provider_call` | Before LLM call | messages, config |
| `:after_provider_call` | After LLM response | response, tool_calls |
| `:before_tool_call` | Before tool execution | tool_calls (filter/approve) |
| `:after_tool_call` | After tool execution | tool_results |
| `:on_stream_event` | Per streaming event | stream_event (transform/suppress) |

## Built-in Middleware

### Logger

Logs events at each hook point via `Logger.debug`:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  middleware: [Agora.Middleware.Logger]
)
```

### MaxTokens

Halts if estimated token count exceeds a budget:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  middleware: [Agora.Middleware.MaxTokens.new(max_tokens: 4000)]
)
```

### Timeout

Cooperative wall-clock timeout across iterations:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  middleware: [Agora.Middleware.Timeout.new(timeout_ms: 30_000)]
)
```

### ToolApproval

Gates tool execution with an approval function:

```elixir
approve_fn = fn tool_calls ->
  # Only allow calculator
  allowed = Enum.filter(tool_calls, &(&1.name == "calculator"))
  {:filter, allowed}
end

config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  tools: [Agora.Tool.Calculator],
  middleware: [Agora.Middleware.ToolApproval.new(approve_fn: approve_fn)]
)
```

The approval function can return:
- `:approve` -- allow all tool calls
- `{:reject, reason}` -- block all tool calls
- `{:filter, calls}` -- allow only specific calls

## Write a Module Middleware

```elixir
defmodule MyApp.Middleware.RequestId do
  @behaviour Agora.Middleware

  @impl true
  def call(%{hook: :before_provider_call} = ctx, next) do
    # Add a request ID to metadata
    metadata = Map.put(ctx.metadata, __MODULE__, %{
      request_id: System.unique_integer([:positive])
    })
    next.(%{ctx | metadata: metadata})
  end

  def call(ctx, next), do: next.(ctx)
end
```

## Write a Closure Middleware

Parameterized middleware use factory functions that return closures:

```elixir
defmodule MyApp.Middleware.ContentFilter do
  def new(opts) do
    blocked_words = Keyword.fetch!(opts, :blocked_words)

    fn ctx, next ->
      if ctx.hook == :after_provider_call do
        content = ctx.response.content || ""
        if Enum.any?(blocked_words, &String.contains?(content, &1)) do
          {:halt, Agora.Error.new(:middleware_error, "Content blocked")}
        else
          next.(ctx)
        end
      else
        next.(ctx)
      end
    end
  end
end

# Usage
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  middleware: [MyApp.Middleware.ContentFilter.new(blocked_words: ["forbidden"])]
)
```

## Streaming Middleware

The `:on_stream_event` hook fires for each streaming event:

```elixir
upcase_middleware = fn ctx, next ->
  if ctx.hook == :on_stream_event && ctx.stream_event.type == :text_delta do
    event = ctx.stream_event
    upper_text = String.upcase(event.data.text)
    new_event = %{event | data: %{text: upper_text}}
    next.(%{ctx | stream_event: new_event})
  else
    next.(ctx)
  end
end
```

Suppress events by setting `stream_event` to nil:

```elixir
filter_middleware = fn ctx, next ->
  if ctx.hook == :on_stream_event && ctx.stream_event.type == :tool_call_delta do
    next.(%{ctx | stream_event: nil})
  else
    next.(ctx)
  end
end
```

## Composing Middleware

Middleware execute in order. Each calls `next.(ctx)` to continue the chain:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  middleware: [
    Agora.Middleware.Logger,
    Agora.Middleware.Timeout.new(timeout_ms: 30_000),
    Agora.Middleware.MaxTokens.new(max_tokens: 4000),
    MyApp.Middleware.RequestId
  ]
)
```

## Halting

Return `{:halt, reason}` to stop execution. The agent treats halts as errors with no message appended to history:

```elixir
fn ctx, next ->
  if some_condition?(ctx) do
    {:halt, Agora.Error.new(:middleware_error, "Halted by policy")}
  else
    next.(ctx)
  end
end
```

## Metadata Persistence

Middleware metadata persists across loop iterations within a single `run/2` call. Namespace your metadata by module to avoid collisions:

```elixir
metadata = Map.put(ctx.metadata, MyApp.Middleware.Tracker, %{
  iteration_count: count + 1
})
next.(%{ctx | metadata: metadata})
```
