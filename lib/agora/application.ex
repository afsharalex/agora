defmodule Agora.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: Agora.EventBus.Registry},
      {Task.Supervisor, name: Agora.ToolSupervisor},
      {Task.Supervisor, name: Agora.WorkflowTaskSupervisor},
      Agora.Agent.Supervisor,
      Agora.Orchestrator.RunnerSupervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Agora.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
