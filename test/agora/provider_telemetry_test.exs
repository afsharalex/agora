defmodule Agora.ProviderTelemetryTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message, Provider}

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

  defp provider_events do
    [
      [:agora, :provider, :call, :start],
      [:agora, :provider, :call, :stop],
      [:agora, :provider, :call, :exception]
    ]
  end

  describe "Provider.chat/3 telemetry" do
    test "successful call emits start and stop" do
      ref = attach_handler(provider_events())

      config = AgentConfig.new!(provider: :echo, model: "echo")
      messages = [Message.user("Hello")]

      {:ok, _response} = Provider.chat(:echo, messages, config)

      assert_receive {^ref, [:agora, :provider, :call, :start],
                      %{monotonic_time: _, system_time: _}, start_meta}

      assert start_meta.provider == :echo
      assert start_meta.model == "echo"
      assert start_meta.message_count == 1

      assert_receive {^ref, [:agora, :provider, :call, :stop], %{duration: _, monotonic_time: _},
                      stop_meta}

      assert stop_meta.provider == :echo
      assert stop_meta.model == "echo"
      assert stop_meta.message_count == 1
      refute Map.has_key?(stop_meta, :error)
    end

    test "error return emits stop with error in metadata" do
      ref = attach_handler(provider_events())

      config =
        AgentConfig.new!(provider: :echo, model: "echo", provider_opts: [echo_mode: :error])

      messages = [Message.user("Hello")]

      {:error, _} = Provider.chat(:echo, messages, config)

      assert_receive {^ref, [:agora, :provider, :call, :start], _, _}

      assert_receive {^ref, [:agora, :provider, :call, :stop], _, stop_meta}
      assert %Error{} = stop_meta.error
    end

    test "provider raise emits exception event" do
      ref = attach_handler(provider_events())

      counter = :counters.new(1, [:atomics])

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(counter, 1, 1)
              raise "provider boom"
            end
          ]
        )

      messages = [Message.user("Hello")]

      assert_raise RuntimeError, "provider boom", fn ->
        Provider.chat(:echo, messages, config)
      end

      assert_receive {^ref, [:agora, :provider, :call, :start], _, _}

      assert_receive {^ref, [:agora, :provider, :call, :exception],
                      %{duration: _, monotonic_time: _}, exc_meta}

      assert exc_meta.kind == :error
      assert %RuntimeError{message: "provider boom"} = exc_meta.reason
    end

    test "resolution failure does not emit provider telemetry" do
      ref = attach_handler(provider_events())

      config = AgentConfig.new!(provider: :echo, model: "echo")
      messages = [Message.user("Hello")]

      {:error, _} = Provider.chat(:nonexistent_provider_xyz, messages, config)

      refute_receive {^ref, [:agora, :provider, :call, :start], _,
                      %{provider: :nonexistent_provider_xyz}}
    end

    test "metadata contains provider, model, message_count only" do
      ref = attach_handler(provider_events())

      config =
        AgentConfig.new!(
          provider: :echo,
          model: "echo",
          provider_opts: [api_key: "sk-secret-123"]
        )

      messages = [Message.user("Hello"), Message.user("World")]

      {:ok, _} = Provider.chat(:echo, messages, config)

      assert_receive {^ref, [:agora, :provider, :call, :start], _, start_meta}

      assert start_meta.provider == :echo
      assert start_meta.model == "echo"
      assert start_meta.message_count == 2
      refute Map.has_key?(start_meta, :config)
      refute Map.has_key?(start_meta, :api_key)
    end
  end
end
