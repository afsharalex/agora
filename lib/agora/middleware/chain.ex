defmodule Agora.Middleware.Chain do
  @moduledoc """
  Executes a middleware chain using Plug-style `next` composition.

  Each middleware entry receives a context and a `next` function. Calling
  `next.(ctx)` passes control to the next middleware in the chain. Returning
  `{:halt, reason}` stops the chain.

  ## Error Safety

  The chain wraps each middleware invocation in try/catch. Invalid entries,
  raises, throws, exits, and unexpected return values are all converted to
  `{:halt, %Error{type: :middleware_error}}` — middleware bugs never crash
  the agent process.
  """

  alias Agora.Error
  alias Agora.Middleware.Context

  @doc """
  Runs a list of middleware entries against the given context.

  Returns `{:ok, context}` if all middleware pass through, or
  `{:halt, reason}` if any middleware halts the chain.

  An empty middleware list returns `{:ok, context}` immediately.
  """
  @spec run([term()], Context.t()) :: {:ok, Context.t()} | {:halt, term()}
  def run([], context), do: {:ok, context}

  def run(middleware, context) do
    chain = compose(middleware)
    chain.(context)
  end

  defp compose(middleware) do
    terminal = fn ctx -> {:ok, ctx} end

    middleware
    |> Enum.reverse()
    |> Enum.reduce(terminal, fn mw, next ->
      fn ctx -> safe_invoke(mw, ctx, next) end
    end)
  end

  defp safe_invoke(module, ctx, next) when is_atom(module) do
    result = module.call(ctx, next)
    validate_return(result, inspect(module))
  rescue
    e ->
      {:halt,
       middleware_error("Middleware #{inspect(module)} raised: #{Exception.message(e)}", module)}
  catch
    :exit, reason ->
      {:halt,
       middleware_error("Middleware #{inspect(module)} exited: #{inspect(reason)}", module)}

    :throw, value ->
      {:halt, middleware_error("Middleware #{inspect(module)} threw: #{inspect(value)}", module)}
  end

  defp safe_invoke(fun, ctx, next) when is_function(fun, 2) do
    result = fun.(ctx, next)
    validate_return(result, "anonymous function")
  rescue
    e ->
      {:halt, middleware_error("Middleware function raised: #{Exception.message(e)}", :anonymous)}
  catch
    :exit, reason ->
      {:halt, middleware_error("Middleware function exited: #{inspect(reason)}", :anonymous)}

    :throw, value ->
      {:halt, middleware_error("Middleware function threw: #{inspect(value)}", :anonymous)}
  end

  defp safe_invoke(invalid, _ctx, _next) do
    {:halt, middleware_error("Invalid middleware entry: #{inspect(invalid)}", :invalid)}
  end

  defp validate_return({:ok, %Context{}} = result, _label), do: result
  defp validate_return({:halt, _reason} = result, _label), do: result

  defp validate_return(other, label) do
    {:halt,
     middleware_error(
       "Middleware #{label} returned invalid value: #{inspect(other)}. " <>
         "Expected {:ok, %Context{}} or {:halt, reason}",
       label
     )}
  end

  defp middleware_error(message, mw) do
    Error.new(:middleware_error, message, %{middleware: inspect(mw)})
  end
end
