defmodule Agora.Telemetry.EventBusBridge do
  @moduledoc """
  Forwards orchestration-level telemetry events to the EventBus for pub/sub consumption.

  This bridge is opt-in. When attached, it listens for `[:agora, :mode, :event]`
  telemetry events and broadcasts the contained `ModeEvent` to EventBus subscribers.

  ## Usage

      # Attach (idempotent — re-attaches with new options)
      Agora.Telemetry.EventBusBridge.attach(topic: :mode_events)

      # Subscribe to events
      Agora.EventBus.subscribe(:mode_events)

      # Events arrive as {Agora.EventBus, :mode_events, %ModeEvent{}}
      receive do
        {Agora.EventBus, :mode_events, event} -> IO.inspect(event)
      end

      # Detach (idempotent — safe to call when not attached)
      Agora.Telemetry.EventBusBridge.detach()

  ## Options

    * `:topic` — EventBus topic to broadcast on (default: `:mode_events`)

  """

  @handler_id "agora.mode_event_bus_bridge"

  @doc """
  Attaches the telemetry-to-EventBus bridge.

  Idempotent — if already attached, detaches first then re-attaches with new options.
  """
  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    topic = Keyword.get(opts, :topic, :mode_events)
    _ = :telemetry.detach(@handler_id)

    :telemetry.attach(
      @handler_id,
      [:agora, :mode, :event],
      &__MODULE__.handle_event/4,
      %{topic: topic}
    )
  end

  @doc """
  Detaches the telemetry-to-EventBus bridge.

  Idempotent — safe to call when not currently attached.
  """
  @spec detach() :: :ok
  def detach do
    case :telemetry.detach(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc false
  def handle_event([:agora, :mode, :event], _measurements, metadata, config) do
    Agora.EventBus.broadcast(config.topic, metadata.event)
  end
end
