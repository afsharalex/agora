defmodule Agora.Middleware do
  @moduledoc """
  Behaviour for middleware that intercepts the agent reasoning loop.

  Middleware provides composable interceptors at four hook points in the
  agent loop: before/after provider calls and before/after tool execution.

  ## Implementing Middleware

  Module-based middleware implements the `call/2` callback:

      defmodule MyMiddleware do
        @behaviour Agora.Middleware

        @impl true
        def call(ctx, next) do
          # pre-processing
          {:ok, ctx} = next.(ctx)
          # post-processing
          {:ok, ctx}
        end
      end

  ## Parameterized Middleware

  For middleware that needs configuration, use a factory function that
  returns a 2-arity closure:

      defmodule MyMiddleware do
        def new(opts) do
          max = Keyword.fetch!(opts, :max)
          fn ctx, next ->
            if over_limit?(ctx, max), do: {:halt, error}, else: next.(ctx)
          end
        end
      end

  Both module atoms and 2-arity functions are valid middleware entries
  in `AgentConfig.middleware`.
  """

  alias Agora.Middleware.Context

  @type next :: (Context.t() -> {:ok, Context.t()} | {:halt, term()})

  @type middleware ::
          module()
          | (Context.t(), next() -> {:ok, Context.t()} | {:halt, term()})

  @doc """
  Invoked for each hook point in the middleware chain.

  Must call `next.(ctx)` to continue the chain, or return `{:halt, reason}`
  to stop processing. The `reason` is conventionally an `%Agora.Error{}`.
  """
  @callback call(context :: Context.t(), next :: next()) ::
              {:ok, Context.t()} | {:halt, term()}
end
