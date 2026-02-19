defmodule Agora.Provider.AnthropicConfigTest do
  @moduledoc """
  Tests for Anthropic provider application-level config fallbacks.

  These tests mutate Application env so they run with async: false.
  """
  use ExUnit.Case, async: false

  alias Agora.{AgentConfig, Error, Message}
  alias Agora.Provider.Anthropic

  setup do
    original_key = Application.get_env(:agora, :anthropic_api_key)
    original_base_url = Application.get_env(:agora, :anthropic_base_url)
    original_timeout = Application.get_env(:agora, :anthropic_timeout)

    on_exit(fn ->
      restore_env(:anthropic_api_key, original_key)
      restore_env(:anthropic_base_url, original_base_url)
      restore_env(:anthropic_timeout, original_timeout)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:agora, key)
  defp restore_env(key, value), do: Application.put_env(:agora, key, value)

  defp stub_ok do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "OK"}],
          "stop_reason" => "end_turn"
        })
      )
    end)
  end

  defp base_config do
    AgentConfig.new!(
      provider: :anthropic,
      model: "claude-sonnet-4-20250514",
      provider_opts: [req_options: [plug: {Req.Test, __MODULE__}, retry: false]]
    )
  end

  describe "API key resolution" do
    test "returns auth_error when no API key is available" do
      Application.delete_env(:agora, :anthropic_api_key)
      cfg = base_config()

      assert {:error,
              %Error{type: :auth_error, message: "Missing API key for Anthropic provider"}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "returns auth_error when provider_opts api_key is nil" do
      Application.delete_env(:agora, :anthropic_api_key)

      cfg =
        AgentConfig.new!(
          provider: :anthropic,
          model: "claude-sonnet-4-20250514",
          provider_opts: [
            api_key: nil,
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:error,
              %Error{type: :auth_error, message: "Missing API key for Anthropic provider"}} =
               Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "falls back to application config anthropic_api_key" do
      Req.Test.stub(__MODULE__, fn conn ->
        [api_key] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert api_key == "app-config-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      Application.put_env(:agora, :anthropic_api_key, "app-config-key")
      cfg = base_config()

      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "provider_opts api_key takes precedence over app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        [api_key] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert api_key == "explicit-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      Application.put_env(:agora, :anthropic_api_key, "app-config-key")

      cfg =
        AgentConfig.new!(
          provider: :anthropic,
          model: "claude-sonnet-4-20250514",
          provider_opts: [
            api_key: "explicit-key",
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end
  end

  describe "namespaced config fallback" do
    test "reads anthropic_base_url from app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "custom-anthropic.example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      Application.put_env(:agora, :anthropic_api_key, "test-key")
      Application.put_env(:agora, :anthropic_base_url, "https://custom-anthropic.example.com")
      cfg = base_config()

      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "reads anthropic_timeout from app config" do
      stub_ok()

      Application.put_env(:agora, :anthropic_api_key, "test-key")
      Application.put_env(:agora, :anthropic_timeout, 30_000)
      cfg = base_config()

      # Verifies the config path doesn't crash; the timeout value is used
      # as receive_timeout in the Req request
      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end

    test "provider_opts base_url takes precedence over app config" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "override.example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn"
          })
        )
      end)

      Application.put_env(:agora, :anthropic_api_key, "test-key")
      Application.put_env(:agora, :anthropic_base_url, "https://should-not-use.example.com")

      cfg =
        AgentConfig.new!(
          provider: :anthropic,
          model: "claude-sonnet-4-20250514",
          provider_opts: [
            base_url: "https://override.example.com",
            req_options: [plug: {Req.Test, __MODULE__}, retry: false]
          ]
        )

      assert {:ok, _msg} = Anthropic.chat([Message.user("Hi")], cfg)
    end
  end
end
