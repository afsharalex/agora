defmodule Agora.ProviderTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error, Message, Provider}

  describe "resolve/1" do
    test "resolves :echo to Echo provider" do
      assert {:ok, Agora.Provider.Echo} = Provider.resolve(:echo)
    end

    test "resolves :anthropic to Anthropic provider" do
      assert {:ok, Agora.Provider.Anthropic} = Provider.resolve(:anthropic)
    end

    test "resolves :openai to OpenAI provider" do
      assert {:ok, Agora.Provider.OpenAI} = Provider.resolve(:openai)
    end

    test "resolves a custom module implementing chat/2" do
      assert {:ok, Agora.Provider.Echo} = Provider.resolve(Agora.Provider.Echo)
    end

    test "returns error for unknown provider" do
      assert {:error, %Error{type: :config_error}} = Provider.resolve(:nonexistent)
    end

    test "returns error for module without chat/2" do
      assert {:error, %Error{type: :config_error}} = Provider.resolve(String)
    end
  end

  describe "chat/3" do
    test "delegates to the resolved provider" do
      {:ok, config} = AgentConfig.new(provider: :echo, model: "echo")
      messages = [Message.user("Hello")]

      assert {:ok, %Message{role: :assistant, content: "Echo: Hello"}} =
               Provider.chat(:echo, messages, config)
    end

    test "propagates resolution errors" do
      {:ok, config} = AgentConfig.new(provider: :echo, model: "echo")

      assert {:error, %Error{type: :config_error}} =
               Provider.chat(:nonexistent, [Message.user("Hi")], config)
    end

    test "propagates provider errors" do
      {:ok, config} =
        AgentConfig.new(
          provider: :echo,
          model: "echo",
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :timeout,
            echo_error_message: "Timed out"
          ]
        )

      assert {:error, %Error{type: :timeout, message: "Timed out"}} =
               Provider.chat(:echo, [Message.user("Hi")], config)
    end
  end

  describe "get_provider_opt/3" do
    test "reads from provider_opts first" do
      {:ok, config} =
        AgentConfig.new(provider: :echo, model: "echo", provider_opts: [api_key: "from-opts"])

      assert Provider.get_provider_opt(config, :api_key) == "from-opts"
    end

    test "falls back to application config" do
      {:ok, config} = AgentConfig.new(provider: :echo, model: "echo")
      # No :some_random_key in provider_opts or app config
      assert Provider.get_provider_opt(config, :some_random_key, "default") == "default"
    end
  end
end
