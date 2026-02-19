defmodule Agora.Tool do
  @moduledoc """
  Behaviour for defining tools that agents can invoke.

  A tool is a named, self-describing function that an LLM can call.
  Implementing modules declare their name, description, JSON Schema
  for arguments, and an `execute/2` callback.

  ## Example

      defmodule MyApp.SearchTool do
        @behaviour Agora.Tool

        @impl true
        def name, do: "search"

        @impl true
        def description, do: "Search the web for information"

        @impl true
        def schema do
          Agora.Tool.Schema.object(%{
            "query" => Agora.Tool.Schema.string(description: "Search query")
          }, required: ["query"])
        end

        @impl true
        def execute(%{"query" => query}, _context) do
          {:ok, "Results for: \#{query}"}
        end
      end

  Tools can also be created inline with `Agora.Tool.FunctionTool`.
  """

  alias Agora.Tool.FunctionTool

  @type tool :: module() | FunctionTool.t()

  @doc "Returns the tool's unique name."
  @callback name() :: String.t()

  @doc "Returns a human-readable description of what the tool does."
  @callback description() :: String.t()

  @doc "Returns a JSON Schema map describing the tool's expected arguments."
  @callback schema() :: map()

  @doc "Executes the tool with the given arguments and context."
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, any()}

  @doc "Returns the timeout in milliseconds for this tool. Defaults to 30_000."
  @callback timeout() :: pos_integer()

  @optional_callbacks [timeout: 0]

  @doc """
  Converts a tool (module or FunctionTool) to the definition map format
  that providers consume.

  Returns a map with `"name"`, `"description"`, and `"parameters"` keys.
  """
  @spec to_definition(tool()) :: map()
  def to_definition(module) when is_atom(module) do
    %{
      "name" => module.name(),
      "description" => module.description(),
      "parameters" => module.schema()
    }
  end

  def to_definition(%FunctionTool{} = ft) do
    %{
      "name" => ft.name,
      "description" => ft.description,
      "parameters" => ft.schema
    }
  end

  @doc """
  Resolves a tool by name from a list of tools.

  Returns `{:ok, tool}` or `{:error, %Agora.Error{}}`.
  """
  @spec resolve(String.t(), [tool()]) :: {:ok, tool()} | {:error, Agora.Error.t()}
  def resolve(name, tools) when is_binary(name) and is_list(tools) do
    result =
      Enum.find(tools, fn
        mod when is_atom(mod) -> mod.name() == name
        %FunctionTool{name: n} -> n == name
      end)

    case result do
      nil -> {:error, Agora.Error.new(:tool_error, "Unknown tool: #{name}")}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Executes a tool with the given arguments and context.

  Dispatches to the module's `execute/2` callback or the FunctionTool's function.
  """
  @spec execute(tool(), map(), map()) :: {:ok, any()} | {:error, any()}
  def execute(module, args, context) when is_atom(module) do
    module.execute(args, context)
  end

  def execute(%FunctionTool{function: fun}, args, context) do
    fun.(args, context)
  end

  @doc """
  Returns the timeout for a tool in milliseconds.

  Falls back to 30_000 if the tool does not implement the optional `timeout/0` callback.
  """
  @spec timeout(tool()) :: pos_integer()
  def timeout(module) when is_atom(module) do
    if function_exported?(module, :timeout, 0) do
      module.timeout()
    else
      30_000
    end
  end

  def timeout(%FunctionTool{timeout: timeout}), do: timeout

  @doc """
  Returns the name of a tool.
  """
  @spec tool_name(tool()) :: String.t()
  def tool_name(module) when is_atom(module), do: module.name()
  def tool_name(%FunctionTool{name: name}), do: name
end
