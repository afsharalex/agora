defmodule Agora.Middleware.ChainTest do
  use ExUnit.Case, async: true

  alias Agora.Middleware.{Chain, Context}
  alias Agora.{AgentConfig, Error}

  defp sample_context(attrs \\ []) do
    defaults = [
      hook: :before_provider_call,
      config: AgentConfig.new!(provider: :echo, model: "echo")
    ]

    Context.new(Keyword.merge(defaults, attrs))
  end

  # A module-based middleware for testing
  defmodule PassthroughMiddleware do
    @behaviour Agora.Middleware

    @impl true
    def call(ctx, next) do
      next.(ctx)
    end
  end

  defmodule MarkerMiddleware do
    @behaviour Agora.Middleware

    @impl true
    def call(ctx, next) do
      order = Map.get(ctx.metadata, :order, [])
      ctx = %{ctx | metadata: Map.put(ctx.metadata, :order, order ++ [:module_marker])}
      next.(ctx)
    end
  end

  defmodule HaltingMiddleware do
    @behaviour Agora.Middleware

    @impl true
    def call(_ctx, _next) do
      {:halt, Error.new(:middleware_error, "halted by module")}
    end
  end

  defmodule RaisingMiddleware do
    @behaviour Agora.Middleware

    @impl true
    def call(_ctx, _next) do
      raise "middleware boom"
    end
  end

  defmodule ThrowingMiddleware do
    @behaviour Agora.Middleware

    @impl true
    def call(_ctx, _next) do
      throw(:middleware_throw)
    end
  end

  defmodule ExitingMiddleware do
    @behaviour Agora.Middleware

    @impl true
    def call(_ctx, _next) do
      exit(:middleware_exit)
    end
  end

  defmodule BadReturnMiddleware do
    @behaviour Agora.Middleware

    @impl true
    def call(_ctx, _next) do
      :ok
    end
  end

  describe "run/2" do
    test "empty list returns {:ok, context} unchanged" do
      ctx = sample_context()
      assert {:ok, ^ctx} = Chain.run([], ctx)
    end

    test "single middleware invoked" do
      mw = fn ctx, next ->
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :visited, true)}
        next.(ctx)
      end

      ctx = sample_context()
      assert {:ok, result} = Chain.run([mw], ctx)
      assert result.metadata[:visited] == true
    end

    test "multiple middleware execute in order" do
      mw1 = fn ctx, next ->
        order = Map.get(ctx.metadata, :order, [])
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :order, order ++ [:first])}
        next.(ctx)
      end

      mw2 = fn ctx, next ->
        order = Map.get(ctx.metadata, :order, [])
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :order, order ++ [:second])}
        next.(ctx)
      end

      mw3 = fn ctx, next ->
        order = Map.get(ctx.metadata, :order, [])
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :order, order ++ [:third])}
        next.(ctx)
      end

      ctx = sample_context()
      assert {:ok, result} = Chain.run([mw1, mw2, mw3], ctx)
      assert result.metadata[:order] == [:first, :second, :third]
    end

    test "halt short-circuits remaining middleware" do
      mw1 = fn ctx, next ->
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :first, true)}
        next.(ctx)
      end

      mw2 = fn _ctx, _next ->
        {:halt, Error.new(:middleware_error, "stopped")}
      end

      mw3 = fn ctx, next ->
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :third, true)}
        next.(ctx)
      end

      ctx = sample_context()
      assert {:halt, %Error{message: "stopped"}} = Chain.run([mw1, mw2, mw3], ctx)
    end

    test "module-based middleware works" do
      ctx = sample_context()
      assert {:ok, ^ctx} = Chain.run([PassthroughMiddleware], ctx)
    end

    test "module-based middleware can modify context" do
      ctx = sample_context()
      assert {:ok, result} = Chain.run([MarkerMiddleware], ctx)
      assert result.metadata[:order] == [:module_marker]
    end

    test "module-based middleware can halt" do
      ctx = sample_context()
      assert {:halt, %Error{message: "halted by module"}} = Chain.run([HaltingMiddleware], ctx)
    end

    test "closure-based middleware works" do
      mw = fn ctx, next ->
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :closure, true)}
        next.(ctx)
      end

      ctx = sample_context()
      assert {:ok, result} = Chain.run([mw], ctx)
      assert result.metadata[:closure] == true
    end

    test "mixed list (modules + closures) works" do
      closure = fn ctx, next ->
        order = Map.get(ctx.metadata, :order, [])
        ctx = %{ctx | metadata: Map.put(ctx.metadata, :order, order ++ [:closure])}
        next.(ctx)
      end

      ctx = sample_context()
      assert {:ok, result} = Chain.run([MarkerMiddleware, closure], ctx)
      assert result.metadata[:order] == [:module_marker, :closure]
    end
  end

  describe "error safety" do
    test "middleware that raises → {:halt, %Error{type: :middleware_error}}" do
      ctx = sample_context()

      assert {:halt, %Error{type: :middleware_error, message: msg}} =
               Chain.run([RaisingMiddleware], ctx)

      assert msg =~ "raised"
      assert msg =~ "middleware boom"
    end

    test "middleware that throws → {:halt, %Error{type: :middleware_error}}" do
      ctx = sample_context()

      assert {:halt, %Error{type: :middleware_error, message: msg}} =
               Chain.run([ThrowingMiddleware], ctx)

      assert msg =~ "threw"
      assert msg =~ "middleware_throw"
    end

    test "middleware that exits → {:halt, %Error{type: :middleware_error}}" do
      ctx = sample_context()

      assert {:halt, %Error{type: :middleware_error, message: msg}} =
               Chain.run([ExitingMiddleware], ctx)

      assert msg =~ "exited"
      assert msg =~ "middleware_exit"
    end

    test "closure that raises → {:halt, %Error{type: :middleware_error}}" do
      mw = fn _ctx, _next -> raise "closure boom" end
      ctx = sample_context()
      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "raised"
      assert msg =~ "closure boom"
    end

    test "closure that throws → {:halt, %Error{type: :middleware_error}}" do
      mw = fn _ctx, _next -> throw(:closure_throw) end
      ctx = sample_context()
      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "threw"
    end

    test "closure that exits → {:halt, %Error{type: :middleware_error}}" do
      mw = fn _ctx, _next -> exit(:closure_exit) end
      ctx = sample_context()
      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "exited"
    end

    test "invalid return value (bare :ok) → {:halt, %Error{type: :middleware_error}}" do
      ctx = sample_context()

      assert {:halt, %Error{type: :middleware_error, message: msg}} =
               Chain.run([BadReturnMiddleware], ctx)

      assert msg =~ "returned invalid value"
    end

    test "invalid return value from closure → {:halt, %Error{type: :middleware_error}}" do
      mw = fn _ctx, _next -> :ok end
      ctx = sample_context()
      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "returned invalid value"
    end

    test "invalid middleware entry (integer) → {:halt, %Error{type: :middleware_error}}" do
      ctx = sample_context()
      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([42], ctx)
      assert msg =~ "Invalid middleware entry"
    end

    test "invalid middleware entry (wrong-arity function) → {:halt, %Error{type: :middleware_error}}" do
      mw = fn _ctx -> :ok end
      ctx = sample_context()
      assert {:halt, %Error{type: :middleware_error, message: msg}} = Chain.run([mw], ctx)
      assert msg =~ "Invalid middleware entry"
    end

    test "downstream middleware not called after halt" do
      downstream_called = :counters.new(1, [:atomics])

      halting = fn _ctx, _next ->
        {:halt, Error.new(:middleware_error, "stop")}
      end

      downstream = fn ctx, next ->
        :counters.add(downstream_called, 1, 1)
        next.(ctx)
      end

      ctx = sample_context()
      assert {:halt, _} = Chain.run([halting, downstream], ctx)
      assert :counters.get(downstream_called, 1) == 0
    end
  end
end
