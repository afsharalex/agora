defmodule Agora.AgentConfigTest do
  use ExUnit.Case, async: true

  alias Agora.{AgentConfig, Error}

  @valid_opts [provider: :anthropic, model: "claude-sonnet-4-20250514"]

  describe "new/1" do
    test "creates config with required fields" do
      assert {:ok, config} = AgentConfig.new(@valid_opts)

      assert config.provider == :anthropic
      assert config.model == "claude-sonnet-4-20250514"
    end

    test "applies defaults for optional fields" do
      assert {:ok, config} = AgentConfig.new(@valid_opts)

      assert config.instructions == ""
      assert config.tools == []
      assert config.memory == nil
      assert config.middleware == []
      assert config.max_iterations == 10
      assert config.name == nil
      assert config.provider_opts == []
    end

    test "accepts all optional fields" do
      opts =
        @valid_opts ++
          [
            instructions: "Be helpful",
            tools: [:search],
            memory: [backend: :ets],
            middleware: [:logging],
            max_iterations: 5,
            name: "researcher",
            provider_opts: [api_key: "sk-test"]
          ]

      assert {:ok, config} = AgentConfig.new(opts)

      assert config.instructions == "Be helpful"
      assert config.tools == [:search]
      assert config.memory == [backend: :ets]
      assert config.middleware == [:logging]
      assert config.max_iterations == 5
      assert config.name == "researcher"
      assert config.provider_opts == [api_key: "sk-test"]
    end

    test "returns validation error when provider is missing" do
      assert {:error, %Error{type: :validation_error}} = AgentConfig.new(model: "test")
    end

    test "returns validation error when model is missing" do
      assert {:error, %Error{type: :validation_error}} = AgentConfig.new(provider: :anthropic)
    end

    test "returns validation error for invalid max_iterations" do
      opts = @valid_opts ++ [max_iterations: 0]
      assert {:error, %Error{type: :validation_error}} = AgentConfig.new(opts)
    end

    test "returns validation error for non-integer max_iterations" do
      opts = @valid_opts ++ [max_iterations: "ten"]
      assert {:error, %Error{type: :validation_error}} = AgentConfig.new(opts)
    end
  end

  describe "new!/1" do
    test "returns config on valid input" do
      config = AgentConfig.new!(@valid_opts)
      assert config.provider == :anthropic
    end

    test "raises ArgumentError on invalid input" do
      assert_raise ArgumentError, fn ->
        AgentConfig.new!([])
      end
    end
  end

  describe "schema/0" do
    test "returns the NimbleOptions schema" do
      schema = AgentConfig.schema()
      assert Keyword.keyword?(schema)
      assert Keyword.has_key?(schema, :provider)
      assert Keyword.has_key?(schema, :model)
    end
  end
end
