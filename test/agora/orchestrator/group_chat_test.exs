defmodule Agora.Orchestrator.GroupChatTest do
  use ExUnit.Case, async: true

  alias Agora.Orchestrator.{GroupChat, ChatRoom, Runner}
  alias Agora.{AgentConfig, Message}

  describe "behaviour" do
    test "implements Agora.Orchestrator behaviour" do
      behaviours =
        GroupChat.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Agora.Orchestrator in behaviours
    end
  end

  describe "init/1" do
    test "delegates to ChatRoom.init/1" do
      config = %{agent_names: [:a, :b]}
      assert GroupChat.init(config) == ChatRoom.init(config)
    end

    test "returns error for empty agents" do
      assert {:error, _} = GroupChat.init(%{agent_names: []})
    end
  end

  describe "full round-trip via Runner" do
    test "works identically to ChatRoom" do
      config = AgentConfig.new!(provider: :echo, model: "echo")
      agents = %{alice: config, bob: config}

      termination =
        Agora.Orchestrator.TerminationCondition.max_turns(2)

      {:ok, runner} =
        Runner.start_link(
          orchestrator: GroupChat,
          agents: agents,
          termination: termination,
          max_turns: 100
        )

      {:ok, response} = Runner.run(runner, "Hello group!")
      assert %Message{} = response
      assert response.role == :assistant

      GenServer.stop(runner)
    end
  end
end
