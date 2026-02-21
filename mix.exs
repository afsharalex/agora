defmodule Agora.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/afsharalex/agora"

  def project do
    [
      app: :agora,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ],

      # Hex
      description: "Multi-agent runtime framework for Elixir leveraging the BEAM actor model.",
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,

      # ExDoc
      name: "Agora",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Agora.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.0", only: :test},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(lib docs guides assets .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Agora",
      extras: [
        {"README.md", title: "Overview"},
        {"CHANGELOG.md", title: "Changelog"},
        {"docs/internal/Design-v0.md", title: "Design Document"},
        {"guides/getting-started.md", title: "Getting Started"},
        {"guides/architecture.md", title: "Architecture"},
        {"guides/providers.md", title: "Providers"},
        {"guides/tools.md", title: "Tools"},
        {"guides/middleware.md", title: "Middleware"},
        {"guides/orchestration.md", title: "Orchestration"},
        {"guides/workflows.md", title: "Workflows"},
        {"guides/execution-modes.md", title: "Execution Modes"}
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [
          Agora,
          Agora.Agent,
          Agora.Agent.Lifecycle,
          Agora.Agent.Lifecycle.StateConfig,
          Agora.Agent.Supervisor,
          Agora.AgentConfig,
          Agora.Message,
          Agora.Error,
          Agora.Config,
          Agora.Execution,
          Agora.CancelToken,
          Agora.ContextPolicy
        ],
        Providers: [
          Agora.Provider,
          Agora.Provider.Anthropic,
          Agora.Provider.OpenAI,
          Agora.Provider.Echo
        ],
        Tools: [
          Agora.Tool,
          Agora.Tool.FunctionTool,
          Agora.Tool.Schema,
          Agora.ToolBroker,
          Agora.Tool.Calculator,
          Agora.Tool.DateTime
        ],
        Middleware: [
          Agora.Middleware,
          Agora.Middleware.Chain,
          Agora.Middleware.Context,
          Agora.Middleware.Logger,
          Agora.Middleware.MaxTokens,
          Agora.Middleware.Timeout,
          Agora.Middleware.ToolApproval
        ],
        Orchestration: [
          Agora.Orchestrator,
          Agora.Orchestrator.Runner,
          Agora.Orchestrator.RunnerSupervisor,
          Agora.Orchestrator.TerminationCondition,
          Agora.Orchestrator.Single,
          Agora.Orchestrator.RoundRobin,
          Agora.Orchestrator.Supervisor,
          Agora.Orchestrator.ChatRoom,
          Agora.Orchestrator.GroupChat
        ],
        Memory: [
          Agora.Memory,
          Agora.Memory.Buffer,
          Agora.Memory.File
        ],
        Streaming: [
          Agora.Stream,
          Agora.StreamEvent,
          Agora.Provider.SSE,
          Agora.Provider.StreamAccumulator
        ],
        Workflows: [
          Agora.Workflow,
          Agora.Workflow.Builder,
          Agora.Workflow.Definition,
          Agora.Workflow.DSL,
          Agora.Workflow.Executor,
          Agora.Workflow.Step,
          Agora.Workflow.Edge,
          Agora.Workflow.CheckpointStore
        ],
        Observability: [
          Agora.Telemetry,
          Agora.EventBus
        ]
      ]
    ]
  end
end
