defmodule Agora.Provider do
  @moduledoc """
  Behaviour and resolution for LLM providers.

  Providers implement a single `chat/2` callback that takes a list of messages
  and an agent config, returning either an assistant message or a structured error.

  ## Resolution

  Provider atoms are resolved to modules via `resolve/1`:

      :echo      → Agora.Provider.Echo
      :anthropic → Agora.Provider.Anthropic
      :openai    → Agora.Provider.OpenAI

  Any other atom is checked for a module that exports `chat/2`.
  """

  alias Agora.{AgentConfig, Config, Error, Message}

  @callback chat([Message.t()], AgentConfig.t()) :: {:ok, Message.t()} | {:error, Error.t()}

  @known_providers %{
    echo: Agora.Provider.Echo,
    anthropic: Agora.Provider.Anthropic,
    openai: Agora.Provider.OpenAI
  }

  @doc """
  Resolves a provider atom to its implementation module.

  Known providers are mapped directly. Unknown atoms are checked for
  a module that exports `chat/2`. Returns an error if resolution fails.

  ## Examples

      iex> {:ok, mod} = Agora.Provider.resolve(:echo)
      iex> mod
      Agora.Provider.Echo

  """
  @spec resolve(atom()) :: {:ok, module()} | {:error, Error.t()}
  def resolve(provider) when is_atom(provider) do
    case Map.fetch(@known_providers, provider) do
      {:ok, mod} ->
        {:ok, mod}

      :error ->
        if Code.ensure_loaded?(provider) and function_exported?(provider, :chat, 2) do
          {:ok, provider}
        else
          Error.wrap(:config_error, "Unknown provider: #{inspect(provider)}")
        end
    end
  end

  @doc """
  Convenience function that resolves a provider and delegates to `chat/2`.

  ## Examples

      iex> {:ok, config} = Agora.AgentConfig.new(provider: :echo, model: "echo")
      iex> {:ok, msg} = Agora.Provider.chat(:echo, [Agora.Message.user("Hello")], config)
      iex> msg.content
      "Echo: Hello"

  """
  @spec chat(atom(), [Message.t()], AgentConfig.t()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def chat(provider, messages, %AgentConfig{} = config) do
    with {:ok, mod} <- resolve(provider) do
      mod.chat(messages, config)
    end
  end

  @doc """
  Reads a provider option from config, falling back to application config.

  Checks `config.provider_opts[key]` first, then `Agora.Config.get(key, default)`.
  """
  @spec get_provider_opt(AgentConfig.t(), atom(), term()) :: term()
  def get_provider_opt(%AgentConfig{} = config, key, default \\ nil) do
    case Keyword.fetch(config.provider_opts, key) do
      {:ok, value} -> value
      :error -> Config.get(key, default)
    end
  end
end
