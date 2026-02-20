defmodule Agora.Middleware.Context do
  @moduledoc """
  Context struct threaded through the middleware chain.

  Each hook point in the agent reasoning loop constructs a `Context` with the
  relevant fields populated. Middleware can read and modify fields according
  to the hook-specific semantics described below.

  ## Field Semantics by Hook

  | Hook                   | messages     | response    | tool_calls           | tool_results    | config              |
  |------------------------|-------------|-------------|----------------------|-----------------|---------------------|
  | `:before_provider_call`| Modifiable  | nil         | []                   | []              | Modifiable (per-iter)|
  | `:after_provider_call` | Read        | Modifiable  | Modifiable (controls flow) | []       | Read                |
  | `:before_tool_call`    | Read        | Read        | Modifiable/filterable| []              | Read                |
  | `:after_tool_call`     | Read        | Read (filtered) | Read (approved)  | Modifiable      | Read                |

  At `:after_provider_call`, modifying `tool_calls` controls whether tool execution
  occurs: clearing the list skips tools entirely, while adding calls triggers execution
  even when the provider returned none.

  ## Metadata

  The `metadata` map persists across iterations within a single `run/2` call.
  Each middleware should namespace its keys under its own module atom to avoid
  collisions (e.g. `ctx.metadata[Agora.Middleware.Timeout]`).
  """

  alias Agora.{AgentConfig, Message, ToolCall, ToolResult}

  @type hook ::
          :before_provider_call
          | :after_provider_call
          | :before_tool_call
          | :after_tool_call

  @type t :: %__MODULE__{
          hook: hook(),
          messages: [Message.t()],
          response: Message.t() | nil,
          tool_calls: [ToolCall.t()],
          tool_results: [ToolResult.t()],
          config: AgentConfig.t(),
          metadata: map()
        }

  defstruct [
    :hook,
    :config,
    messages: [],
    response: nil,
    tool_calls: [],
    tool_results: [],
    metadata: %{}
  ]

  @doc """
  Creates a new context from the given attributes.

  ## Examples

      iex> ctx = Agora.Middleware.Context.new(hook: :before_provider_call, messages: [], config: config)
      iex> ctx.hook
      :before_provider_call

  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
