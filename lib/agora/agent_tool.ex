defmodule Agora.AgentTool do
  @moduledoc """
  Creates a tool that delegates to another agent.

  Wraps an `AgentConfig` as a `FunctionTool` so that a parent agent can
  invoke a child agent as a tool call. The child agent runs as an ephemeral
  one-shot process via `Agora.run/2`.

  ## Depth Guard

  To prevent runaway recursion when agents invoke other agent tools,
  a depth counter is propagated through `provider_opts` → tool context.
  When `max_depth` is exceeded, the tool returns an error instead of
  spawning another agent.

  Depth flows across process boundaries:
  1. `agent_tool/2` captures `max_depth` in the closure
  2. At execution time, reads current depth from the tool context
  3. Injects `depth + 1` into the child config's `provider_opts`
  4. The child agent's loops build tool context with the incremented depth

  ## Cancel Token Propagation

  Cancel tokens are automatically propagated from parent to child agent
  via the tool context. When the parent agent's cancel token is set, it
  is passed through the tool broker context and forwarded to
  `Agora.run/3` for the child agent.

  ## Examples

      research_tool = Agora.agent_tool(researcher,
        name: "research_agent",
        description: "Delegates research tasks to a specialized agent."
      )

      supervisor = Agora.agent(:anthropic, "claude-sonnet-4-20250514",
        instructions: "Use research_agent for research tasks.",
        tools: [research_tool]
      )

  """

  alias Agora.{AgentConfig, Error}
  alias Agora.Tool.{FunctionTool, Schema}

  @default_max_depth 3
  @default_timeout 300_000

  @doc """
  Creates a `FunctionTool` that delegates to a child agent.

  ## Options

    * `:name` — tool name (default: agent's `:name` or `"agent_tool"`)
    * `:description` — tool description (default: generic delegation description)
    * `:max_depth` — maximum nesting depth (default: #{@default_max_depth})
    * `:timeout` — tool execution timeout in ms (default: #{@default_timeout})

  """
  @spec new(AgentConfig.t(), keyword()) :: FunctionTool.t()
  def new(%AgentConfig{} = config, opts \\ []) do
    name = Keyword.get(opts, :name, config.name || "agent_tool")
    description = Keyword.get(opts, :description, "Delegates a task to the #{name} agent.")
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    unless is_integer(max_depth) and max_depth > 0 do
      raise ArgumentError, "max_depth must be a positive integer, got: #{inspect(max_depth)}"
    end

    FunctionTool.new!(
      name: name,
      description: description,
      schema:
        Schema.object(
          %{"task" => Schema.string(description: "The task to delegate to the agent.")},
          required: ["task"]
        ),
      function: build_function(config, max_depth),
      timeout: timeout
    )
  end

  defp build_function(config, max_depth) do
    fn %{"task" => task}, ctx ->
      current_depth = Map.get(ctx, :agora_tool_depth, 0)
      cancel_token = Map.get(ctx, :cancel_token)

      if current_depth >= max_depth do
        {:error, "Agent tool depth #{current_depth} exceeds max_depth #{max_depth}"}
      else
        child_provider_opts =
          Keyword.put(config.provider_opts, :_agora_tool_depth, current_depth + 1)

        child_config = struct!(config, provider_opts: child_provider_opts)
        opts = if cancel_token, do: [cancel_token: cancel_token], else: []

        case Agora.run(child_config, task, opts) do
          {:ok, message} -> {:ok, message.content || ""}
          {:error, %Error{} = error} -> {:error, to_string(error)}
        end
      end
    end
  end
end
