defmodule Agora.Workflow do
  @moduledoc """
  A workflow definition consisting of steps and edges forming a DAG.

  Workflows are built using `Agora.Workflow.Builder` and executed by
  `Agora.Workflow.Executor`. They complement orchestrators: orchestrators
  use LLM-driven routing (autonomous), while workflows use predefined
  DAG execution order (deterministic).

  ## Fields

    * `:steps` — map of step ID to `%Step{}` structs
    * `:edges` — list of `%Edge{}` structs defining the DAG
    * `:metadata` — arbitrary metadata map

  """

  alias Agora.Workflow.{Edge, Step}

  @type t :: %__MODULE__{
          steps: %{atom() => Step.t()},
          edges: [Edge.t()],
          metadata: map()
        }

  defstruct steps: %{}, edges: [], metadata: %{}
end
