defmodule Agora.Middleware.Context do
  @moduledoc """
  Context struct threaded through the middleware chain.

  Each hook point in the agent reasoning loop constructs a `Context` with the
  relevant fields populated. Middleware can read and modify fields according
  to the hook-specific semantics described below.

  ## Field Semantics by Hook

  | Hook                   | messages     | response    | tool_calls           | tool_results    | config              | stream_event    |
  |------------------------|-------------|-------------|----------------------|-----------------|---------------------|-----------------|
  | `:before_provider_call`| Modifiable  | nil         | []                   | []              | Modifiable (per-iter)| nil             |
  | `:after_provider_call` | Read        | Modifiable  | Modifiable (controls flow) | []       | Read                | nil             |
  | `:before_tool_call`    | Read        | Read        | Modifiable/filterable| []              | Read                | nil             |
  | `:after_tool_call`     | Read        | Read (filtered) | Read (approved)  | Modifiable      | Read                | nil             |
  | `:on_stream_event`     | Read        | nil         | []                   | []              | Read                | Modifiable      |

  At `:after_provider_call`, modifying `tool_calls` controls whether tool execution
  occurs: clearing the list skips tools entirely, while adding calls triggers execution
  even when the provider returned none.

  At `:on_stream_event`, middleware can transform or filter events by modifying
  `stream_event`. Setting it to `nil` suppresses the event (not forwarded to caller).
  Returning `{:halt, reason}` cancels the stream.

  ## Metadata

  The `metadata` map persists across iterations within a single `run/2` call.
  Each middleware should namespace its keys under its own module atom to avoid
  collisions (e.g. `ctx.metadata[Agora.Middleware.Timeout]`).
  """

  alias Agora.{AgentConfig, Message, StreamEvent, ToolCall, ToolResult}

  @type hook ::
          :before_provider_call
          | :after_provider_call
          | :before_tool_call
          | :after_tool_call
          | :on_stream_event

  @type t :: %__MODULE__{
          hook: hook(),
          messages: [Message.t()],
          response: Message.t() | nil,
          tool_calls: [ToolCall.t()],
          tool_results: [ToolResult.t()],
          stream_event: StreamEvent.t() | nil,
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
    stream_event: nil,
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
