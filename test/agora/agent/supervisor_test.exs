defmodule Agora.Agent.SupervisorTest do
  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig}

  defp echo_config(opts \\ []) do
    defaults = [provider: :echo, model: "echo"]
    AgentConfig.new!(Keyword.merge(defaults, opts))
  end

  describe "start_agent/2" do
    test "starts an agent and returns {:ok, pid}" do
      config = echo_config()
      assert {:ok, pid} = Agent.Supervisor.start_agent(config)
      assert Process.alive?(pid)
    end

    test "started agent is functional" do
      config = echo_config()
      {:ok, pid} = Agent.Supervisor.start_agent(config)

      assert {:ok, response} = Agent.run(pid, "Hi")
      assert response.content == "Echo: Hi"
    end

    test "supports name option" do
      config = echo_config()
      name = :"sup_test_agent_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Agent.Supervisor.start_agent(config, name: name)

      assert Agent.get_status(name) == :idle
    end
  end

  describe "stop_agent/1" do
    test "terminates an agent" do
      config = echo_config()
      {:ok, pid} = Agent.Supervisor.start_agent(config)
      assert Process.alive?(pid)

      assert :ok = Agent.Supervisor.stop_agent(pid)
      refute Process.alive?(pid)
    end

    test "returns error for unknown pid" do
      # A dead pid won't be a child
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert {:error, :not_found} = Agent.Supervisor.stop_agent(pid)
    end
  end
end
