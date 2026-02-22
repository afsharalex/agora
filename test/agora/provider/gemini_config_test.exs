defmodule Agora.Provider.GeminiConfigTest do
  @moduledoc """
  Tests for Gemini provider application-level config fallbacks.

  These tests mutate Application env so they run with async: false.
  """
  use ExUnit.Case, async: false

  alias Agora.{AgentConfig, Error, Message}
  alias Agora.Provider.Gemini

  setup do
    original_gemini_key = Application.get_env(:agora, :gemini_api_key)
    original_google_key = Application.get_env(:agora, :google_api_key)
    original_base_url = Application.get_env(:agora, :gemini_base_url)
    original_timeout = Application.get_env(:agora, :gemini_timeout)

    on_exit(fn ->
      restore_env(:gemini_api_key, original_gemini_key)
      restore_env(:google_api_key, original_google_key)
      restore_env(:gemini_base_url, original_base_url)
      restore_env(:gemini_timeout, original_timeout)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:agora, key)
  defp restore_env(key, value), do: Application.put_env(:agora, key, value)

  defp ok_response do
    %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => "OK"}]},
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 10,
        "candidatesTokenCount" => 5,
        "totalTokenCount" => 15
      },
      "modelVersion" => "gemini-2.0-flash"
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
      provider: :gemini,
      model: "gemini-2.0-flash",
      provider_opts: [req_options: [plug: {Req.Test, __MODULE__}, retry: false]]
    )
  end

  describe "API key resolution" do
    test "returns auth_error when no API key is available" do
      Application.delete_env(:agora, :gemini_api_key)
      Application.delete_env(:agora, :google_api_key)
      cfg = base_config()

      assert {:error, %Error{type: :auth_error, message: "Missing API key for Gemini provider"}} =
               Gemini.chat([Message.user("Hi")], cfg)
    end

    test "falls back to gemini_api_key app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.query_string =~ "key=gemini-app-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.delete_env(:agora, :google_api_key)
      Application.put_env(:agora, :gemini_api_key, "gemini-app-key")
      cfg = base_config()

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "falls back to google_api_key app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.query_string =~ "key=google-app-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.delete_env(:agora, :gemini_api_key)
      Application.put_env(:agora, :google_api_key, "google-app-key")
      cfg = base_config()

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "gemini_api_key takes precedence over google_api_key" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.query_string =~ "key=gemini-key"
        refute conn.query_string =~ "google-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :gemini_api_key, "gemini-key")
      Application.put_env(:agora, :google_api_key, "google-key")
      cfg = base_config()

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "provider_opts api_key takes precedence over app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.query_string =~ "key=explicit-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :gemini_api_key, "app-config-key")

      cfg =
        AgentConfig.new!(
          provider: :gemini,
          model: "gemini-2.0-flash",
          provider_opts: [
            api_key: "explicit-key",
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end
  end

  describe "namespaced config fallback" do
    test "reads gemini_base_url from app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "custom-gemini.example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :gemini_api_key, "test-key")
      Application.put_env(:agora, :gemini_base_url, "https://custom-gemini.example.com")
      cfg = base_config()

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "reads gemini_timeout from app config" do
      stub_ok()

      Application.put_env(:agora, :gemini_api_key, "test-key")
      Application.put_env(:agora, :gemini_timeout, 30_000)
      cfg = base_config()

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end

    test "provider_opts base_url takes precedence over app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "override.example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(ok_response()))
      end)

      Application.put_env(:agora, :gemini_api_key, "test-key")
      Application.put_env(:agora, :gemini_base_url, "https://should-not-use.example.com")

      cfg =
        AgentConfig.new!(
          provider: :gemini,
          model: "gemini-2.0-flash",
          provider_opts: [
            base_url: "https://override.example.com",
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:ok, _msg} = Gemini.chat([Message.user("Hi")], cfg)
    end
  end
end
