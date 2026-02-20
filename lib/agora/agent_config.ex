defmodule Agora.AgentConfig do
  @moduledoc """
  Configuration for an individual agent, validated via NimbleOptions.

  ## Required Fields

    * `:provider` - atom identifying the LLM provider (e.g. `:anthropic`, `:openai`)
    * `:model` - string model identifier (e.g. `"claude-sonnet-4-20250514"`)

  ## Optional Fields

    * `:instructions` - system prompt for the agent (default: `""`)
    * `:tools` - list of tool definitions (default: `[]`)
    * `:memory` - memory configuration keyword list (default: `nil`)
    * `:middleware` - list of middleware modules or 2-arity functions (see `Agora.Middleware`) (default: `[]`)
    * `:max_iterations` - maximum reasoning loop iterations (default: `10`)
    * `:name` - human-readable agent name (default: `nil`)
    * `:provider_opts` - per-agent provider overrides (default: `[]`)

  """

  @type t :: %__MODULE__{
          provider: atom(),
          model: String.t(),
          instructions: String.t(),
          tools: list(),
          memory: keyword() | nil,
          middleware: list(),
          max_iterations: pos_integer(),
          name: String.t() | nil,
          provider_opts: keyword()
        }

  @derive Jason.Encoder
  defstruct [
    :provider,
    :model,
    :name,
    instructions: "",
    tools: [],
    memory: nil,
    middleware: [],
    max_iterations: 10,
    provider_opts: []
  ]

  @schema [
    provider: [
      type: :atom,
      required: true,
      doc: "LLM provider identifier (e.g. :anthropic, :openai)"
    ],
    model: [
      type: :string,
      required: true,
      doc: "Model identifier (e.g. \"claude-sonnet-4-20250514\")"
    ],
    instructions: [
      type: :string,
      default: "",
      doc: "System prompt for the agent"
    ],
    tools: [
      type: {:list, :any},
      default: [],
      doc: "List of tool definitions"
    ],
    memory: [
      type: {:or, [:keyword_list, nil]},
      default: nil,
      doc: "Memory configuration"
    ],
    middleware: [
      type: {:list, :any},
      default: [],
      doc: "List of middleware modules or 2-arity functions (see Agora.Middleware)"
    ],
    max_iterations: [
      type: :pos_integer,
      default: 10,
      doc: "Maximum reasoning loop iterations"
    ],
    name: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "Human-readable agent name"
    ],
    provider_opts: [
      type: :keyword_list,
      default: [],
      doc: "Per-agent provider overrides (e.g. API key, base URL)"
    ]
  ]

  @doc """
  Returns the NimbleOptions schema used for validation.
  """
  @spec schema() :: keyword()
  def schema, do: @schema

  @doc """
  Creates a validated agent config from a keyword list.

  Returns `{:ok, %AgentConfig{}}` on success or `{:error, %Agora.Error{}}` on failure.

  ## Examples

      iex> {:ok, config} = Agora.AgentConfig.new(provider: :anthropic, model: "claude-sonnet-4-20250514")
      iex> config.provider
      :anthropic

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Agora.Error.t()}
  def new(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} ->
        {:ok, struct!(__MODULE__, validated)}

      {:error, %NimbleOptions.ValidationError{message: message}} ->
        {:error, Agora.Error.new(:validation_error, message)}
    end
  end

  @doc """
  Creates a validated agent config, raising on invalid input.

  ## Examples

      iex> config = Agora.AgentConfig.new!(provider: :anthropic, model: "claude-sonnet-4-20250514")
      iex> config.model
      "claude-sonnet-4-20250514"

  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  @doc """
  Converts the config's tools list to provider-consumable definition maps.

  Handles three tool formats:
    * Module implementing `Agora.Tool` behaviour
    * `%Agora.Tool.FunctionTool{}` struct
    * Plain map (passed through as-is)

  """
  @spec tool_definitions(t()) :: [map()]
  def tool_definitions(%__MODULE__{tools: tools}) do
    Enum.map(tools, fn
      tool when is_atom(tool) -> Agora.Tool.to_definition(tool)
      %Agora.Tool.FunctionTool{} = ft -> Agora.Tool.to_definition(ft)
      %{} = map -> map
    end)
  end
end
