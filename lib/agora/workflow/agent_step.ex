defmodule Agora.Workflow.AgentStep do
  @moduledoc """
  Convenience for building agent-backed workflow steps.

  Produces step spec tuples compatible with `Agora.Workflow.Builder` and
  `Agora.Workflow.Patterns`. The `AgentConfig` is used directly as the step
  handler — the executor already knows how to run agent handlers.

  ## Examples

      alias Agora.Workflow.AgentStep

      spec = AgentStep.spec(:research, researcher_config,
        input_mapper: fn results -> "Research: \#{results[:input]}" end,
        timeout: 60_000
      )

      workflow =
        Builder.new()
        |> Builder.step(spec)
        |> Builder.build!()

  """

  alias Agora.AgentConfig

  @type step_spec ::
          {atom(), AgentConfig.t()}
          | {atom(), AgentConfig.t(), keyword()}

  @doc """
  Builds a step spec tuple from an agent config.

  Returns `{id, config}` or `{id, config, opts}` suitable for use with
  `Builder.step/2`, `Builder.chain/2`, or `Patterns.sequential/2`.

  ## Options

    * `:input_mapper` — `(map() -> String.t() | Message.t())` to transform upstream results
    * `:timeout` — step timeout in milliseconds
    * `:retry` — retry count on failure
    * `:inputs` — list of upstream step IDs this step depends on

  """
  @spec spec(atom(), AgentConfig.t(), keyword()) :: step_spec()
  def spec(id, %AgentConfig{} = config, opts \\ []) when is_atom(id) do
    if opts == [] do
      {id, config}
    else
      {id, config, opts}
    end
  end
end
