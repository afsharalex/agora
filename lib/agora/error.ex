defmodule Agora.Error do
  @moduledoc """
  Structured error type for the Agora framework.

  Errors are returned as `{:error, %Agora.Error{}}` tuples rather than raised
  as exceptions. This keeps the control flow explicit and composable.
  """

  @type error_type ::
          :provider_error
          | :tool_error
          | :validation_error
          | :timeout
          | :rate_limit
          | :auth_error
          | :config_error
          | :iteration_limit
          | :middleware_error
          | :memory_error
          | :orchestration_error
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          metadata: map()
        }

  @valid_types [
    :provider_error,
    :tool_error,
    :validation_error,
    :timeout,
    :rate_limit,
    :auth_error,
    :config_error,
    :iteration_limit,
    :middleware_error,
    :memory_error,
    :orchestration_error,
    :unknown
  ]

  @derive Jason.Encoder
  defstruct [:type, :message, metadata: %{}]

  @doc """
  Creates a new error struct.

  ## Examples

      iex> Agora.Error.new(:provider_error, "API returned 500", %{status: 500})
      %Agora.Error{type: :provider_error, message: "API returned 500", metadata: %{status: 500}}

  """
  @spec new(error_type(), String.t(), map()) :: t()
  def new(type, message, metadata \\ %{}) when type in @valid_types and is_binary(message) do
    %__MODULE__{type: type, message: message, metadata: metadata}
  end

  @doc """
  Creates an error wrapped in an `{:error, t()}` tuple.

  ## Examples

      iex> Agora.Error.wrap(:timeout, "Request timed out")
      {:error, %Agora.Error{type: :timeout, message: "Request timed out", metadata: %{}}}

  """
  @spec wrap(error_type(), String.t(), map()) :: {:error, t()}
  def wrap(type, message, metadata \\ %{}) do
    {:error, new(type, message, metadata)}
  end

  @doc """
  Returns the list of valid error types.
  """
  @spec valid_types() :: [error_type()]
  def valid_types, do: @valid_types

  defimpl String.Chars do
    def to_string(%Agora.Error{type: type, message: message}) do
      "[#{type}] #{message}"
    end
  end
end
