defmodule Agora.CancelToken do
  @moduledoc """
  Lock-free cancellation token using `:atomics` for cross-process coordination.

  CancelToken provides boundary-cooperative cancellation — it is checked at
  orchestration loop boundaries (before each step in `Agora.Orchestrator.Runner`).
  It does **not** interrupt mid-flight provider HTTP calls or tool executions,
  matching the same cooperative model as `Agora.Middleware.Timeout`.

  Middleware-level cancellation checks may be added in a future phase.

  ## Example

      token = Agora.CancelToken.new()
      Agora.CancelToken.cancelled?(token)  #=> false

      Agora.CancelToken.cancel(token)
      Agora.CancelToken.cancelled?(token)  #=> true

  Cancellation is monotonic and idempotent — once cancelled, a token stays
  cancelled. Multiple calls to `cancel/1` are safe.
  """

  @type t :: %__MODULE__{ref: :atomics.atomics_ref()}

  defstruct [:ref]

  @doc """
  Creates a new uncancelled token.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{ref: :atomics.new(1, signed: false)}
  end

  @doc """
  Cancels the token. Idempotent — safe to call multiple times.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref}) do
    :atomics.put(ref, 1, 1)
    :ok
  end

  @doc """
  Returns `true` if the token has been cancelled.
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{ref: ref}) do
    :atomics.get(ref, 1) == 1
  end
end
