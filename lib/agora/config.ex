defmodule Agora.Config do
  @moduledoc """
  Application-level configuration for Agora.

  Wraps `Application.get_env/3` with Agora-specific conventions.
  """

  @doc """
  Gets a configuration value for the given key, with an optional default.

  ## Examples

      Agora.Config.get(:default_provider)
      Agora.Config.get(:some_key, :fallback)

  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) do
    Application.get_env(:agora, key, default)
  end

  @doc """
  Returns all Agora application configuration as a keyword list.
  """
  @spec all() :: keyword()
  def all do
    Application.get_all_env(:agora)
  end

  @doc """
  Gets the API key for a provider.

  Convention: the provider atom is suffixed with `_api_key`.

  ## Examples

      Agora.Config.api_key(:anthropic)
      # reads Application.get_env(:agora, :anthropic_api_key)

  """
  @spec api_key(atom()) :: String.t() | nil
  def api_key(provider) when is_atom(provider) do
    key = String.to_atom("#{provider}_api_key")
    get(key)
  end

  @doc """
  Returns the configured default provider.
  """
  @spec default_provider() :: atom() | nil
  def default_provider, do: get(:default_provider)

  @doc """
  Returns the configured default model.
  """
  @spec default_model() :: String.t() | nil
  def default_model, do: get(:default_model)

  @doc """
  Fetches a required configuration value. Raises `ArgumentError` if missing.

  ## Examples

      Agora.Config.fetch!(:default_provider)
      # => :anthropic

  """
  @spec fetch!(atom()) :: term()
  def fetch!(key) do
    case get(key) do
      nil -> raise ArgumentError, "missing required Agora config: #{inspect(key)}"
      value -> value
    end
  end
end
