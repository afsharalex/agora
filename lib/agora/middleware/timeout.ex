defmodule Agora.Middleware.Timeout do
  @moduledoc """
  Middleware that enforces a cooperative wall-clock timeout.

  Active at all hook points. Sets a deadline on first invocation and checks
  it on every subsequent call. Halts with `:timeout` if the deadline has
  passed.

  This is a **cooperative** timeout — it only checks at hook boundaries.
  A long `Provider.chat/3` or `ToolBroker.execute/2` call will not be
  interrupted mid-flight. For per-call enforcement, combine with
  `provider_opts: [timeout: N]` and per-tool timeouts.

  ## Usage

      middleware = [Agora.Middleware.Timeout.new(timeout_ms: 30_000)]

  ## Options

    * `:timeout_ms` (required) — wall-clock timeout in milliseconds

  The deadline is stored in namespaced metadata at
  `ctx.metadata[Agora.Middleware.Timeout]` and persists across iterations.
  """

  alias Agora.Error
  alias Agora.Middleware.Context

  @doc """
  Creates a Timeout middleware closure.
  """
  @spec new(keyword()) :: (Context.t(), Agora.Middleware.next() ->
                             {:ok, Context.t()} | {:halt, term()})
  def new(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    fn ctx, next ->
      now = System.monotonic_time(:millisecond)
      my_meta = Map.get(ctx.metadata, __MODULE__, %{})

      case Map.fetch(my_meta, :deadline) do
        {:ok, deadline} ->
          # Subsequent invocation: check deadline
          if now >= deadline do
            elapsed = now - (deadline - timeout_ms)

            {:halt,
             Error.new(
               :timeout,
               "Middleware timeout exceeded: #{elapsed}ms elapsed (limit: #{timeout_ms}ms)",
               %{timeout_ms: timeout_ms, elapsed_ms: elapsed}
             )}
          else
            ctx = %{ctx | metadata: Map.put(ctx.metadata, __MODULE__, my_meta)}
            next.(ctx)
          end

        :error ->
          # First invocation: set deadline and pass through
          deadline = now + timeout_ms
          my_meta = Map.put(my_meta, :deadline, deadline)
          ctx = %{ctx | metadata: Map.put(ctx.metadata, __MODULE__, my_meta)}
          next.(ctx)
      end
    end
  end
end
