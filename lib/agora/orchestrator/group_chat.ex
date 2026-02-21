defmodule Agora.Orchestrator.GroupChat do
  @moduledoc """
  Alias for `Agora.Orchestrator.ChatRoom`.

  Provides the `GroupChat` name for the shared-transcript orchestrator pattern,
  aligning with common multi-agent terminology. All callbacks delegate directly
  to `Agora.Orchestrator.ChatRoom`.

  See `Agora.Orchestrator.ChatRoom` for configuration and behaviour details.
  """

  @behaviour Agora.Orchestrator

  defdelegate init(config), to: Agora.Orchestrator.ChatRoom
  defdelegate next(state, context), to: Agora.Orchestrator.ChatRoom
  defdelegate handle_result(state, agent, result), to: Agora.Orchestrator.ChatRoom
end
