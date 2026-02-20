defmodule Agora.TelemetryTest do
  use ExUnit.Case, async: true

  alias Agora.Telemetry

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

  describe "span/3" do
    test "emits start and stop with correct prefix" do
      ref =
        attach_handler([
          [:test, :span, :start],
          [:test, :span, :stop]
        ])

      result =
        Telemetry.span([:test, :span], %{key: "value"}, fn ->
          {:the_result, %{key: "value"}}
        end)

      assert result == :the_result

      assert_receive {^ref, [:test, :span, :start], %{system_time: _, monotonic_time: _},
                      %{key: "value"}}

      assert_receive {^ref, [:test, :span, :stop], %{duration: _, monotonic_time: _},
                      %{key: "value"}}
    end

    test "emits exception on raise and re-raises" do
      ref =
        attach_handler([
          [:test, :raise, :start],
          [:test, :raise, :exception]
        ])

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span([:test, :raise], %{op: "fail"}, fn ->
          raise "boom"
        end)
      end

      assert_receive {^ref, [:test, :raise, :start], _, %{op: "fail"}}

      assert_receive {^ref, [:test, :raise, :exception], %{duration: _, monotonic_time: _},
                      %{kind: :error, reason: %RuntimeError{}, stacktrace: _}}
    end

    test "merges stop metadata from span function return" do
      ref =
        attach_handler([
          [:test, :meta, :stop]
        ])

      Telemetry.span([:test, :meta], %{base: true}, fn ->
        {:ok, %{base: true, extra: "added"}}
      end)

      assert_receive {^ref, [:test, :meta, :stop], _, %{base: true, extra: "added"}}
    end
  end

  describe "emit/3" do
    test "delegates to :telemetry.execute" do
      ref =
        attach_handler([
          [:test, :emit, :event]
        ])

      Telemetry.emit([:test, :emit, :event], %{count: 1}, %{source: "test"})

      assert_receive {^ref, [:test, :emit, :event], %{count: 1}, %{source: "test"}}
    end
  end
end
