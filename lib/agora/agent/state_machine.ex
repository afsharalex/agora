defmodule Agora.Agent.StateMachine do
  @moduledoc false

  # gen_statem backend for lifecycle-enabled agents.
  # Stub — full implementation added when Lifecycle structs are defined.

  @spec start_link(Agora.AgentConfig.t(), keyword()) :: GenServer.on_start()
  def start_link(_config, _server_opts) do
    {:error, :not_implemented}
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)
    restart = if config.memory, do: :transient, else: :temporary

    %{
      id: Agora.Agent,
      start: {Agora.Agent, :start_link, [opts]},
      restart: restart
    }
  end
end
