defmodule Agora do
  @moduledoc """
  Agora is a multi-agent runtime framework for Elixir.

  It enables users to create collaborative AI agents using the BEAM actor model,
  with provider abstraction, tool execution, middleware, and orchestration patterns.
  """

  @doc """
  Returns the current version of Agora.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:agora, :vsn) |> to_string()
  end
end
