defmodule Agora.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: Agora.EventBus.Registry},
      %{id: :agora_cancel_pg, start: {:pg, :start_link, [Agora.CancelToken.pg_scope()]}},
      {Task.Supervisor, name: Agora.ToolSupervisor},
      {Task.Supervisor, name: Agora.WorkflowTaskSupervisor},
      {Task.Supervisor, name: Agora.StreamSupervisor},
      Agora.Agent.Supervisor,
      Agora.Orchestrator.RunnerSupervisor,
      Agora.Workflow.HandlerRegistry.Default
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Agora.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
