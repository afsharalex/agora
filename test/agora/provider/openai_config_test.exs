defmodule Agora.Provider.OpenAIConfigTest do
  @moduledoc """
  Tests for OpenAI provider application-level config fallbacks.

  These tests mutate Application env so they run with async: false.
  """
  use ExUnit.Case, async: false

  alias Agora.{AgentConfig, Error, Message}
  alias Agora.Provider.OpenAI

  setup do
    original_key = Application.get_env(:agora, :openai_api_key)
    original_base_url = Application.get_env(:agora, :openai_base_url)
    original_timeout = Application.get_env(:agora, :openai_timeout)

    on_exit(fn ->
      restore_env(:openai_api_key, original_key)
      restore_env(:openai_base_url, original_base_url)
      restore_env(:openai_timeout, original_timeout)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:agora, key)
  defp restore_env(key, value), do: Application.put_env(:agora, key, value)

  defp ok_response do
    %{
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => "OK"},
          "finish_reason" => "stop"
        }
      ],
      "model" => "gpt-4o",
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }
  end

  defp stub_ok do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
    end)
  end

  defp base_config do
    AgentConfig.new!(
      provider: :openai,
      model: "gpt-4o",
      provider_opts: [req_options: [plug: {Req.Test, __MODULE__}, retry: false]]
    )
  end

  describe "API key resolution" do
    test "returns auth_error when no API key is available" do
      Application.delete_env(:agora, :openai_api_key)
      cfg = base_config()

      assert {:error, %Error{type: :auth_error, message: "Missing API key for OpenAI provider"}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "returns auth_error when provider_opts api_key is nil" do
      Application.delete_env(:agora, :openai_api_key)

      cfg =
        AgentConfig.new!(
          provider: :openai,
          model: "gpt-4o",
          provider_opts: [
            api_key: nil,
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:error, %Error{type: :auth_error, message: "Missing API key for OpenAI provider"}} =
               OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "falls back to application config openai_api_key" do
      Req.Test.stub(__MODULE__, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer app-config-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :openai_api_key, "app-config-key")
      cfg = base_config()

      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "provider_opts api_key takes precedence over app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer explicit-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :openai_api_key, "app-config-key")

      cfg =
        AgentConfig.new!(
          provider: :openai,
          model: "gpt-4o",
          provider_opts: [
            api_key: "explicit-key",
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end
  end

  describe "namespaced config fallback" do
    test "reads openai_base_url from app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "custom-openai.example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :openai_api_key, "test-key")
      Application.put_env(:agora, :openai_base_url, "https://custom-openai.example.com")
      cfg = base_config()

      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "reads openai_timeout from app config" do
      stub_ok()

      Application.put_env(:agora, :openai_api_key, "test-key")
      Application.put_env(:agora, :openai_timeout, 30_000)
      cfg = base_config()

      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end

    test "provider_opts base_url takes precedence over app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "override.example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :openai_api_key, "test-key")
      Application.put_env(:agora, :openai_base_url, "https://should-not-use.example.com")

      cfg =
        AgentConfig.new!(
          provider: :openai,
          model: "gpt-4o",
          provider_opts: [
            base_url: "https://override.example.com",
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:ok, _msg} = OpenAI.chat([Message.user("Hi")], cfg)
    end
  end
end
