defmodule Agora.Middleware.ToolApproval do
  @moduledoc """
  Middleware that gates tool execution via a user-provided approval function.

  Active at `:before_tool_call` only. The approval function receives the list
  of tool calls and must return one of:

    * `:approve` — all tool calls proceed
    * `{:reject, reason}` — halt with an error
    * `{:filter, approved_calls}` — only approved calls execute;
      halts if the filtered list is empty

  ## Usage

      approve_fn = fn tool_calls ->
        if Enum.any?(tool_calls, &(&1.name == "dangerous_tool")),
          do: {:reject, "dangerous_tool not allowed"},
          else: :approve
      end

      middleware = [Agora.Middleware.ToolApproval.new(approve_fn: approve_fn)]

  ## Options

    * `:approve_fn` (required) — function of type `[ToolCall.t()] -> :approve | {:reject, String.t()} | {:filter, [ToolCall.t()]}`

  """

  alias Agora.Error
  alias Agora.Middleware.Context

  @doc """
  Creates a ToolApproval middleware closure.
  """
  @spec new(keyword()) :: (Context.t(), Agora.Middleware.next() ->
                             {:ok, Context.t()} | {:halt, term()})
  def new(opts) do
    approve_fn = Keyword.fetch!(opts, :approve_fn)

    fn ctx, next ->
      case ctx.hook do
        :before_tool_call ->
          case approve_fn.(ctx.tool_calls) do
            :approve ->
              next.(ctx)

            {:reject, reason} ->
              {:halt,
               Error.new(:middleware_error, "Tool call rejected: #{reason}", %{
                 rejected_tools: Enum.map(ctx.tool_calls, & &1.name)
               })}

            {:filter, approved} when is_list(approved) and approved != [] ->
              next.(%{ctx | tool_calls: approved})

            {:filter, []} ->
              {:halt,
               Error.new(:middleware_error, "All tool calls filtered out", %{
                 original_tools: Enum.map(ctx.tool_calls, & &1.name)
               })}
          end

        _other ->
          next.(ctx)
      end
    end
  end
end
