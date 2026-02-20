defmodule Agora.Middleware.MaxTokens do
  @moduledoc """
  Middleware that enforces a token budget on conversation history.

  Active at `:before_provider_call` only. Estimates token count from message
  content, tool call arguments, and tool result content, then halts if the
  estimate exceeds the configured maximum.

  ## Usage

      middleware = [Agora.Middleware.MaxTokens.new(max_tokens: 4000)]

  ## Options

    * `:max_tokens` (required) — maximum estimated tokens allowed
    * `:chars_per_token` — characters per token for estimation (default: `4`)

  Token estimates are stored in namespaced metadata at
  `ctx.metadata[Agora.Middleware.MaxTokens]`.
  """

  alias Agora.Error
  alias Agora.Middleware.Context

  @default_chars_per_token 4

  @doc """
  Creates a MaxTokens middleware closure.
  """
  @spec new(keyword()) :: (Context.t(), Agora.Middleware.next() ->
                             {:ok, Context.t()} | {:halt, term()})
  def new(opts) do
    max_tokens = Keyword.fetch!(opts, :max_tokens)
    chars_per_token = Keyword.get(opts, :chars_per_token, @default_chars_per_token)

    if not is_integer(chars_per_token) or chars_per_token < 1 do
      raise ArgumentError,
            "chars_per_token must be a positive integer, got: #{inspect(chars_per_token)}"
    end

    fn ctx, next ->
      case ctx.hook do
        :before_provider_call ->
          estimated = estimate_tokens(ctx.messages, chars_per_token)
          metadata = Map.put(ctx.metadata, __MODULE__, %{estimated_tokens: estimated})
          ctx = %{ctx | metadata: metadata}

          if estimated > max_tokens do
            {:halt,
             Error.new(
               :middleware_error,
               "Token budget exceeded: estimated #{estimated} > max #{max_tokens}",
               %{estimated_tokens: estimated, max_tokens: max_tokens}
             )}
          else
            next.(ctx)
          end

        _other ->
          next.(ctx)
      end
    end
  end

  @doc false
  def estimate_tokens(messages, chars_per_token) do
    total_chars =
      Enum.reduce(messages, 0, fn msg, acc ->
        acc + content_chars(msg.content) + tool_calls_chars(msg.tool_calls) +
          tool_results_chars(msg.tool_results)
      end)

    ceil_div(total_chars, chars_per_token)
  end

  defp content_chars(nil), do: 0
  defp content_chars(content) when is_binary(content), do: String.length(content)

  defp tool_calls_chars(tool_calls) when is_list(tool_calls) do
    Enum.reduce(tool_calls, 0, fn tc, acc ->
      name_len = String.length(tc.name || "")

      args_len =
        case Jason.encode(tc.arguments) do
          {:ok, json} -> String.length(json)
          _ -> 0
        end

      acc + name_len + args_len
    end)
  end

  defp tool_calls_chars(_), do: 0

  defp tool_results_chars(tool_results) when is_list(tool_results) do
    Enum.reduce(tool_results, 0, fn tr, acc ->
      acc + content_chars(tr.content)
    end)
  end

  defp tool_results_chars(_), do: 0

  defp ceil_div(num, denom), do: div(num + denom - 1, denom)
end
