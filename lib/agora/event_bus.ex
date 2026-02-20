defmodule Agora.EventBus do
  @moduledoc """
  Registry-backed pub/sub for internal component messaging.

  Provides lightweight topic-based message delivery for UI integration,
  audit trails, and debugging multi-agent systems. NOT automatically wired
  to telemetry — users bridge the two if desired.

  Messages are delivered as `{Agora.EventBus, topic, message}` tuples to
  each subscriber's process mailbox.

  ## Example

      Agora.EventBus.subscribe(:agent_events)
      Agora.EventBus.broadcast(:agent_events, %{status: :completed})

      receive do
        {Agora.EventBus, :agent_events, message} ->
          IO.inspect(message)
      end

  """

  @registry Agora.EventBus.Registry

  @doc """
  Subscribes the calling process to a topic.

  Idempotent — calling twice with the same topic from the same process
  does NOT create duplicate deliveries.

  ## Options

    * No options currently defined; reserved for future use (e.g., filters).

  """
  @spec subscribe(term(), keyword()) :: :ok | {:error, term()}
  def subscribe(topic, opts \\ []) do
    already_subscribed? = topic in Registry.keys(@registry, self())

    if already_subscribed? do
      :ok
    else
      case Registry.register(@registry, topic, opts) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Unsubscribes the calling process from a topic.
  """
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(topic) do
    Registry.unregister(@registry, topic)
  end

  @doc """
  Broadcasts a message to all subscribers of a topic.

  Returns `:ok` always (even with zero subscribers).
  """
  @spec broadcast(term(), term()) :: :ok
  def broadcast(topic, message) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {__MODULE__, topic, message})
    end)
  end
end
