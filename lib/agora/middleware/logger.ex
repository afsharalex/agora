defmodule Agora.Middleware.Logger do
  @moduledoc """
  Middleware that logs events at each hook point.

  Uses Elixir's `Logger.debug/1` to emit structured log messages describing
  the current hook, message counts, tool call names, and result counts.

  This is a module-based middleware (no configuration needed). Add it
  directly to the middleware list:

      config = AgentConfig.new!(
        middleware: [Agora.Middleware.Logger],
        ...
      )

  """

  @behaviour Agora.Middleware

  require Logger

  alias Agora.Middleware.Context

  @impl true
  def call(%Context{hook: :before_provider_call} = ctx, next) do
    Logger.debug(
      "[Agora.Middleware.Logger] before_provider_call: #{length(ctx.messages)} messages"
    )

    next.(ctx)
  end

  def call(%Context{hook: :after_provider_call} = ctx, next) do
    tool_call_count = length(ctx.tool_calls)

    Logger.debug(
      "[Agora.Middleware.Logger] after_provider_call: " <>
        "response=#{inspect_content(ctx.response)}, tool_calls=#{tool_call_count}"
    )

    next.(ctx)
  end

  def call(%Context{hook: :before_tool_call} = ctx, next) do
    tool_names = Enum.map(ctx.tool_calls, & &1.name)

    Logger.debug("[Agora.Middleware.Logger] before_tool_call: tools=#{inspect(tool_names)}")

    next.(ctx)
  end

  def call(%Context{hook: :after_tool_call} = ctx, next) do
    result_count = length(ctx.tool_results)

    Logger.debug("[Agora.Middleware.Logger] after_tool_call: #{result_count} results")

    next.(ctx)
  end

  defp inspect_content(nil), do: "nil"
  defp inspect_content(%{content: nil}), do: "nil"
  defp inspect_content(%{content: c}) when is_binary(c), do: "\"#{String.slice(c, 0..49)}...\""
  defp inspect_content(_), do: "unknown"
end
