defmodule Agora.ErrorTest do
  use ExUnit.Case, async: true

  alias Agora.Error

  describe "new/3" do
    test "creates an error with type, message, and metadata" do
      error = Error.new(:provider_error, "API returned 500", %{status: 500})

      assert error.type == :provider_error
      assert error.message == "API returned 500"
      assert error.metadata == %{status: 500}
    end

    test "defaults metadata to empty map" do
      error = Error.new(:timeout, "Request timed out")

      assert error.metadata == %{}
    end

    test "accepts all valid error types" do
      for type <- Error.valid_types() do
        error = Error.new(type, "test")
        assert error.type == type
      end
    end
  end

  describe "wrap/3" do
    test "returns an {:error, t()} tuple" do
      assert {:error, %Error{} = error} = Error.wrap(:auth_error, "Invalid API key")
      assert error.type == :auth_error
      assert error.message == "Invalid API key"
    end

    test "passes metadata through" do
      assert {:error, error} = Error.wrap(:rate_limit, "Too many requests", %{retry_after: 30})
      assert error.metadata == %{retry_after: 30}
    end
  end

  describe "String.Chars" do
    test "formats error as [type] message" do
      error = Error.new(:config_error, "Missing provider")
      assert to_string(error) == "[config_error] Missing provider"
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      error = Error.new(:unknown, "Something went wrong", %{detail: "oops"})
      json = Jason.encode!(error)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "unknown"
      assert decoded["message"] == "Something went wrong"
      assert decoded["metadata"] == %{"detail" => "oops"}
    end
  end
end
