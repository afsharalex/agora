defmodule Agora.ConfigTest do
  use ExUnit.Case

  alias Agora.Config

  describe "get/2" do
    test "returns configured value" do
      assert Config.get(:default_provider) == :anthropic
    end

    test "returns default for missing key" do
      assert Config.get(:nonexistent, :fallback) == :fallback
    end

    test "returns nil for missing key without default" do
      assert Config.get(:nonexistent) == nil
    end
  end

  describe "api_key/1" do
    test "returns nil when no API key is configured" do
      assert Config.api_key(:some_unconfigured_provider) == nil
    end
  end

  describe "default_provider/0" do
    test "returns the configured default provider" do
      assert Config.default_provider() == :anthropic
    end
  end

  describe "default_model/0" do
    test "returns the configured default model" do
      assert Config.default_model() == "claude-sonnet-4-20250514"
    end
  end

  describe "fetch!/1" do
    test "returns value when present" do
      assert Config.fetch!(:default_provider) == :anthropic
    end

    test "raises ArgumentError when missing" do
      assert_raise ArgumentError, ~r/missing required Agora config/, fn ->
        Config.fetch!(:nonexistent_key)
      end
    end
  end

  describe "all/0" do
    test "returns all Agora config as keyword list" do
      all = Config.all()
      assert Keyword.keyword?(all)
      assert Keyword.get(all, :default_provider) == :anthropic
    end
  end
end
