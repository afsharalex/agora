# Tools

How to create tools for agents, including module-based tools, inline function tools, built-in tools, and the sandbox security model.

## Overview

Tools let agents call external functions. When the LLM returns tool calls, the agent executes them via `Agora.ToolBroker` and feeds results back to the LLM.

## Built-in Tools

### Stateless Tools

These tools have no side effects and don't require any special configuration:

| Tool | Module | Description |
|------|--------|-------------|
| Calculator | `Agora.Tool.Calculator` | Basic arithmetic (add, subtract, multiply, divide) |
| DateTime | `Agora.Tool.DateTime` | Current date/time in configurable formats |
| Think | `Agora.Tool.Think` | Reasoning scratchpad for chain-of-thought |
| Json | `Agora.Tool.Json` | Parse, format, and query JSON data |
| Regex | `Agora.Tool.Regex` | Match, scan, and replace with regular expressions |
| Http | `Agora.Tool.Http` | HTTP requests with SSRF protection |

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  tools: [Agora.Tool.Think, Agora.Tool.Json, Agora.Tool.Http]
)
```

### System Tools (Sandbox Required)

These tools interact with the filesystem and OS. They require a `%Agora.Tool.Sandbox{}` in `tool_opts`:

| Tool | Module | Description |
|------|--------|-------------|
| ReadFile | `Agora.Tool.ReadFile` | Read file contents (UTF-8 or binary/Base64) |
| WriteFile | `Agora.Tool.WriteFile` | Write or append to files (atomic write mode) |
| ListDirectory | `Agora.Tool.ListDirectory` | List directory contents with regex filtering |
| Shell | `Agora.Tool.Shell` | Execute commands with argument lists or shell mode |

```elixir
sandbox = %Agora.Tool.Sandbox{
  working_directory: "/tmp/workspace",
  allowed_paths: ["/tmp/workspace"],
  denied_paths: ["/tmp/workspace/secrets"],
  allowed_commands: ["ls", "grep", "cat", "echo"],
  denied_commands: ["rm", "sudo", "chmod"]
}

config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  tools: [Agora.Tool.ReadFile, Agora.Tool.WriteFile, Agora.Tool.ListDirectory, Agora.Tool.Shell],
  tool_opts: [sandbox: sandbox]
)
```

## Sandbox Security Model

The `Agora.Tool.Sandbox` struct controls what system tools can access:

```elixir
%Agora.Tool.Sandbox{
  working_directory: "/tmp/workspace",    # base for relative paths
  allowed_paths: ["/tmp/workspace"],      # prefix allowlist
  denied_paths: ["/tmp/workspace/.env"],  # prefix denylist (wins over allowed)
  allowed_commands: :all,                 # :all or ["ls", "grep", ...]
  denied_commands: ["rm", "sudo"],        # always denied (wins over allowed)
  max_file_size: 10_485_760,             # 10 MB read limit
  max_output_size: 1_048_576,            # 1 MB shell output limit
  shell_timeout: 30_000,                 # ms for shell commands
  allow_shell_mode: false,               # must explicitly enable shell: true
  env: nil                               # nil = inherit, [{k,v}] = add/override vars
}
```

### Path Validation

- Paths are resolved relative to `working_directory` via `Path.expand/2`
- Symlinks are recursively resolved to their real targets
- Prefix matching (not globs) works for both existing and non-existent paths
- Denied paths always win over allowed paths

### Command Validation

- Commands are normalized to their basename (`/usr/bin/ls` becomes `ls`)
- Denied commands always win over allowed commands
- Shell mode (`shell: true`) requires `allow_shell_mode: true`
- Shell mode validates only the primary command; piped commands are not checked
- **Interpreter bypass**: Commands like `sh -c "rm ..."` bypass the deny list for `rm` since only `sh` is validated. Add interpreters (`sh`, `bash`, `zsh`, `python`, `perl`, `ruby`, `node`) to `denied_commands` when using a restrictive allowlist.

### Environment Variables

By default, commands inherit the process environment. The `env` option is **additive** — it merges with (adds to or overrides) the existing process environment. There is no way to run with a fully clean environment via Erlang's `System.cmd/3`.

```elixir
# Add/override specific variables
sandbox = %Agora.Tool.Sandbox{
  # ... other fields ...
  env: [{"PATH", "/usr/bin"}, {"MY_API_KEY", "secret"}]
}
```

## Create a Module Tool

Implement the `Agora.Tool` behaviour:

```elixir
defmodule MyApp.Tools.Weather do
  @behaviour Agora.Tool

  @impl true
  def name, do: "weather"

  @impl true
  def description, do: "Get current weather for a city"

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string", "description" => "City name"}
      },
      "required" => ["city"]
    }
  end

  @impl true
  def execute(%{"city" => city}, _context) do
    # Call a weather API here
    {:ok, "72F and sunny in #{city}"}
  end

  # Optional: override default timeout (30s)
  # @impl true
  # def timeout, do: 10_000
end
```

Use it in an agent:

```elixir
config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  tools: [MyApp.Tools.Weather]
)
```

## Create an Inline Function Tool

For quick one-off tools without a dedicated module:

```elixir
alias Agora.Tool.FunctionTool

greeting_tool = FunctionTool.new!(%{
  name: "greet",
  description: "Generate a greeting",
  schema: %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string"}
    },
    "required" => ["name"]
  },
  function: fn %{"name" => name}, _ctx ->
    {:ok, "Hello, #{name}!"}
  end
})

config = Agora.AgentConfig.new!(
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  tools: [greeting_tool]
)
```

The function receives `(args, context)` where `args` is a map of validated arguments and `context` contains execution metadata.

## Schema Helpers

`Agora.Tool.Schema` provides helpers for building JSON Schema maps:

```elixir
alias Agora.Tool.Schema

schema = Schema.object(%{
  "query" => Schema.string(description: "Search query"),
  "limit" => Schema.integer(description: "Max results", minimum: 1, maximum: 100),
  "tags" => Schema.array(Schema.string(), description: "Filter tags"),
  "format" => Schema.enum(["json", "text"], description: "Output format")
})
|> Schema.required(["query"])
```

### Available type helpers

| Helper | JSON Schema type |
|--------|-----------------|
| `Schema.string/1` | `"string"` |
| `Schema.integer/1` | `"integer"` |
| `Schema.number/1` | `"number"` |
| `Schema.boolean/1` | `"boolean"` |
| `Schema.array/2` | `"array"` with items schema |
| `Schema.object/2` | `"object"` with properties |
| `Schema.enum/2` | `"string"` with `enum` constraint |
| `Schema.required/2` | Adds `"required"` to object schema |

## Tool Execution Details

Tools are executed via `Agora.ToolBroker`:

- Each tool call runs as a supervised task under `Agora.ToolSupervisor`
- Multiple tool calls in one turn execute in parallel
- Each tool has a deadline-based timeout (default 30s) with `:brutal_kill` shutdown
- Arguments are validated against the tool schema before execution
- Exceptions, throws, and exits are caught and converted to error results
- Results are always returned as `{:ok, [ToolResult.t()]}` -- individual failures become error results

## Testing Tools

Test tools with the Echo provider in `:function` mode:

```elixir
counter = :counters.new(1, [:atomics])

config = Agora.AgentConfig.new!(
  provider: :echo,
  model: "echo",
  tools: [MyApp.Tools.Weather],
  provider_opts: [
    echo_mode: :function,
    echo_function: fn messages, _config ->
      count = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      if count == 0 do
        {:ok, Agora.Message.assistant(nil, [
          Agora.ToolCall.new(%{id: "call_1", name: "weather", arguments: %{"city" => "NYC"}})
        ])}
      else
        {:ok, Agora.Message.assistant("The weather result is in.")}
      end
    end
  ]
)
```
