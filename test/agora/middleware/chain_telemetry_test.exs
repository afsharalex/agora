defmodule Agora.Middleware.ChainTelemetryTest do
  use ExUnit.Case, async: true

  alias Agora.Middleware.{Chain, Context}

  defp attach_handler(events) do
    ref = make_ref()
    test_pid = self()
    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ref
  end

  defp chain_events do
    [
      [:agora, :middleware, :call, :start],
      [:agora, :middleware, :call, :stop]
    ]
  end

  defp make_context(hook \\ :before_provider_call) do
    Context.new(
      hook: hook,
      messages: [],
      config: Agora.AgentConfig.new!(provider: :echo, model: "echo")
    )
  end

  describe "chain telemetry" do
    test "non-empty chain emits start and stop" do
      ref = attach_handler(chain_events())

      passthrough = fn ctx, next -> next.(ctx) end
      context = make_context()

      {:ok, _ctx} = Chain.run([passthrough], context)

      assert_receive {^ref, [:agora, :middleware, :call, :start],
                      %{monotonic_time: _, system_time: _},
                      %{hook: :before_provider_call, middleware_count: 1}}

      assert_receive {^ref, [:agora, :middleware, :call, :stop],
                      %{duration: _, monotonic_time: _},
                      %{hook: :before_provider_call, middleware_count: 1}}
    end

    test "halting middleware emits stop with halt_reason" do
      ref = attach_handler(chain_events())

      halter = fn _ctx, _next -> {:halt, "stopped"} end
      context = make_context()

      {:halt, _reason} = Chain.run([halter], context)

      assert_receive {^ref, [:agora, :middleware, :call, :start], _, _}

      assert_receive {^ref, [:agora, :middleware, :call, :stop], _, %{halt_reason: halt_reason}}

      assert halt_reason =~ "stopped"
    end

    test "empty middleware does not emit telemetry" do
      ref = attach_handler(chain_events())

      context = make_context(:after_provider_call)

      {:ok, _ctx} = Chain.run([], context)

      refute_receive {^ref, [:agora, :middleware, :call, :start], _,
                      %{hook: :after_provider_call, middleware_count: 0}}

      refute_receive {^ref, [:agora, :middleware, :call, :stop], _,
                      %{hook: :after_provider_call, middleware_count: 0}}
    end

    test "metadata contains hook and middleware_count" do
      ref = attach_handler(chain_events())

      mw1 = fn ctx, next -> next.(ctx) end
      mw2 = fn ctx, next -> next.(ctx) end
      context = make_context(:after_tool_call)

      {:ok, _ctx} = Chain.run([mw1, mw2], context)

      assert_receive {^ref, [:agora, :middleware, :call, :start], _,
                      %{hook: :after_tool_call, middleware_count: 2}}

      assert_receive {^ref, [:agora, :middleware, :call, :stop], _,
                      %{hook: :after_tool_call, middleware_count: 2}}
    end

    test "middleware crash still emits stop (via safe_invoke halt)" do
      ref = attach_handler(chain_events())

      crasher = fn _ctx, _next -> raise "middleware boom" end
      context = make_context()

      {:halt, _reason} = Chain.run([crasher], context)

      assert_receive {^ref, [:agora, :middleware, :call, :start], _, _}
      assert_receive {^ref, [:agora, :middleware, :call, :stop], _, %{halt_reason: _}}
    end
  end
end
