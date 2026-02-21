defmodule Agora.Agent.StateMachineTest do
  use ExUnit.Case, async: true

  alias Agora.{Agent, AgentConfig, Message}
  alias Agora.Agent.Lifecycle
  alias Agora.Agent.Lifecycle.StateConfig
  alias Agora.Tool.FunctionTool

  # --- Helpers ---

  defp lifecycle_config(lifecycle_opts, config_overrides \\ []) do
    lifecycle = Lifecycle.new!(lifecycle_opts)

    base =
      Keyword.merge(
        [provider: :echo, model: "echo", lifecycle: lifecycle],
        config_overrides
      )

    AgentConfig.new!(base)
  end

  defp start_agent(config) do
    {:ok, pid} = Agent.start_link(config: config)
    pid
  end

  # A simple tool that returns its name as content
  defp echo_tool(name) do
    %FunctionTool{
      name: name,
      description: "Test tool #{name}",
      schema: %{"type" => "object", "properties" => %{}},
      function: fn _args, _ctx -> {:ok, "#{name}_result"} end
    }
  end

  # --- Tests ---

  describe "basic lifecycle" do
    test "starts in initial state" do
      config =
        lifecycle_config(
          initial_state: :ready,
          states: %{ready: %StateConfig{}}
        )

      pid = start_agent(config)
      assert {:ok, :ready} = Agent.get_lifecycle_state(pid)
    end

    test "runs in a single state" do
      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}}
        )

      pid = start_agent(config)
      {:ok, response} = Agent.run(pid, "Hello!")
      assert response.content == "Echo: Hello!"
      assert {:ok, :active} = Agent.get_lifecycle_state(pid)
    end

    test "preserves messages across runs" do
      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}}
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "First")
      {:ok, _} = Agent.run(pid, "Second")

      messages = Agent.get_messages(pid)
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end

    test "get_status returns :idle between runs" do
      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}}
        )

      pid = start_agent(config)
      assert :idle = Agent.get_status(pid)
    end
  end

  describe "state-specific instructions" do
    test "provider sees state-specific instructions" do
      test_pid = self()

      config =
        lifecycle_config(
          [
            initial_state: :greeting,
            states: %{
              greeting: %StateConfig{instructions: "You are a greeter."},
              farewell: %StateConfig{instructions: "You are a farewell bot."}
            },
            transitions: [
              %{
                from: :greeting,
                to: :farewell,
                trigger: {:message_match, fn msg -> String.contains?(msg.content, "Echo:") end},
                guard: nil
              }
            ]
          ],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, config ->
              send(test_pid, {:provider_call, config.instructions, messages})
              {:ok, Message.assistant("Echo: done")}
            end
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "Hi")

      assert_receive {:provider_call, "You are a greeter.", _messages}

      # Transition should have occurred (message_match on "Echo:")
      assert {:ok, :farewell} = Agent.get_lifecycle_state(pid)

      # Next run should see farewell instructions
      {:ok, _} = Agent.run(pid, "Bye")
      assert_receive {:provider_call, "You are a farewell bot.", _messages}
    end

    test "state instructions do not leak across transitions" do
      # Regression test: old state's instructions must not appear in later provider calls
      test_pid = self()
      calls = :counters.new(1, [:atomics])

      config =
        lifecycle_config(
          [
            initial_state: :a,
            states: %{
              a: %StateConfig{instructions: "State A instructions"},
              b: %StateConfig{instructions: "State B instructions"}
            },
            transitions: [
              %{
                from: :a,
                to: :b,
                trigger:
                  {:message_match,
                   fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
                guard: nil
              }
            ]
          ],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, config ->
              :counters.add(calls, 1, 1)
              n = :counters.get(calls, 1)
              send(test_pid, {:call, n, config.instructions})
              {:ok, Message.assistant("Echo: response #{n}")}
            end
          ]
        )

      pid = start_agent(config)

      # Run 1: in state :a
      {:ok, _} = Agent.run(pid, "msg1")
      assert_receive {:call, 1, "State A instructions"}

      # Now in state :b
      assert {:ok, :b} = Agent.get_lifecycle_state(pid)

      # Run 2: in state :b — must see "State B instructions", NOT "State A instructions"
      {:ok, _} = Agent.run(pid, "msg2")
      assert_receive {:call, 2, "State B instructions"}
    end

    test "nil overlay fields inherit from base config" do
      test_pid = self()

      config =
        lifecycle_config(
          [
            initial_state: :active,
            states: %{active: %StateConfig{}}
          ],
          instructions: "Base instructions",
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, config ->
              send(test_pid, {:instructions, config.instructions})
              {:ok, Message.assistant("done")}
            end
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "test")
      assert_receive {:instructions, "Base instructions"}
    end
  end

  describe "tool_call transitions" do
    test "transitions on tool call trigger" do
      tool = echo_tool("submit")
      calls = :counters.new(1, [:atomics])

      config =
        lifecycle_config(
          [
            initial_state: :collecting,
            states: %{
              collecting: %StateConfig{tools: [tool]},
              processing: %StateConfig{}
            },
            transitions: [
              %{from: :collecting, to: :processing, trigger: {:tool_call, "submit"}, guard: nil}
            ]
          ],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(calls, 1, 1)

              if :counters.get(calls, 1) == 1 do
                {:ok,
                 Message.assistant(nil, [
                   %Agora.ToolCall{id: "tc_1", name: "submit", arguments: %{}}
                 ])}
              else
                {:ok, Message.assistant("Submitted")}
              end
            end
          ]
        )

      pid = start_agent(config)
      assert {:ok, :collecting} = Agent.get_lifecycle_state(pid)

      {:ok, _} = Agent.run(pid, "Submit data")
      assert {:ok, :processing} = Agent.get_lifecycle_state(pid)
    end

    test "no transition when tool_call name doesn't match" do
      tool = echo_tool("search")
      calls = :counters.new(1, [:atomics])

      config =
        lifecycle_config(
          [
            initial_state: :active,
            states: %{active: %StateConfig{tools: [tool]}, done: %StateConfig{}},
            transitions: [
              %{from: :active, to: :done, trigger: {:tool_call, "submit"}, guard: nil}
            ]
          ],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(calls, 1, 1)

              if :counters.get(calls, 1) == 1 do
                {:ok,
                 Message.assistant(nil, [
                   %Agora.ToolCall{id: "tc_1", name: "search", arguments: %{}}
                 ])}
              else
                {:ok, Message.assistant("Search done")}
              end
            end
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "Search")
      assert {:ok, :active} = Agent.get_lifecycle_state(pid)
    end
  end

  describe "tool_result transitions" do
    test "transitions on tool_result predicate" do
      tool = echo_tool("check")
      calls = :counters.new(1, [:atomics])

      config =
        lifecycle_config(
          [
            initial_state: :checking,
            states: %{
              checking: %StateConfig{tools: [tool]},
              confirmed: %StateConfig{}
            },
            transitions: [
              %{
                from: :checking,
                to: :confirmed,
                trigger:
                  {:tool_result, "check", fn result -> result.content == "check_result" end},
                guard: nil
              }
            ]
          ],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn _messages, _config ->
              :counters.add(calls, 1, 1)

              if :counters.get(calls, 1) == 1 do
                {:ok,
                 Message.assistant(nil, [
                   %Agora.ToolCall{id: "tc_1", name: "check", arguments: %{}}
                 ])}
              else
                {:ok, Message.assistant("Check complete")}
              end
            end
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "Run check")
      assert {:ok, :confirmed} = Agent.get_lifecycle_state(pid)
    end
  end

  describe "message_match transitions" do
    test "transitions when final response matches predicate" do
      config =
        lifecycle_config(
          initial_state: :waiting,
          states: %{
            waiting: %StateConfig{},
            done: %StateConfig{}
          },
          transitions: [
            %{
              from: :waiting,
              to: :done,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: nil
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "trigger transition")
      assert {:ok, :done} = Agent.get_lifecycle_state(pid)
    end

    test "no transition when predicate returns false" do
      config =
        lifecycle_config(
          initial_state: :waiting,
          states: %{
            waiting: %StateConfig{},
            done: %StateConfig{}
          },
          transitions: [
            %{
              from: :waiting,
              to: :done,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "NEVER") end},
              guard: nil
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "Hello")
      assert {:ok, :waiting} = Agent.get_lifecycle_state(pid)
    end
  end

  describe "state_timeout transitions" do
    test "transitions after state timeout" do
      config =
        lifecycle_config(
          initial_state: :waiting,
          states: %{
            waiting: %StateConfig{},
            timed_out: %StateConfig{}
          },
          transitions: [
            %{from: :waiting, to: :timed_out, trigger: {:state_timeout, 50}, guard: nil}
          ]
        )

      pid = start_agent(config)
      assert {:ok, :waiting} = Agent.get_lifecycle_state(pid)

      # Wait for the timeout to fire
      Process.sleep(150)
      assert {:ok, :timed_out} = Agent.get_lifecycle_state(pid)
    end
  end

  describe "guard functions" do
    test "guard prevents transition when returning false" do
      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}, done: %StateConfig{}},
          transitions: [
            %{
              from: :active,
              to: :done,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: fn _ctx -> false end
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "test")
      assert {:ok, :active} = Agent.get_lifecycle_state(pid)
    end

    test "guard allows transition when returning true" do
      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}, done: %StateConfig{}},
          transitions: [
            %{
              from: :active,
              to: :done,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: fn ctx -> ctx.from == :active end
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "test")
      assert {:ok, :done} = Agent.get_lifecycle_state(pid)
    end

    test "guard receives transition context with facts" do
      test_pid = self()

      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}, done: %StateConfig{}},
          transitions: [
            %{
              from: :active,
              to: :done,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: fn ctx ->
                send(test_pid, {:guard_ctx, ctx})
                true
              end
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "test")

      assert_receive {:guard_ctx, ctx}
      assert ctx.from == :active
      assert ctx.to == :done
      assert is_map(ctx.facts)
      assert {:done, %Message{}} = ctx.outcome
    end
  end

  describe "first-match transition precedence" do
    test "first matching transition wins" do
      config =
        lifecycle_config(
          initial_state: :start,
          states: %{start: %StateConfig{}, a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{
              from: :start,
              to: :a,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: nil
            },
            %{
              from: :start,
              to: :b,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: nil
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "trigger")
      # First match (:a) should win, not :b
      assert {:ok, :a} = Agent.get_lifecycle_state(pid)
    end
  end

  describe "on_enter/on_exit callbacks" do
    test "on_enter called with :__init__ on initial state" do
      test_pid = self()

      config =
        lifecycle_config(
          initial_state: :ready,
          states: %{ready: %StateConfig{}},
          on_enter: %{
            ready: fn from, to ->
              send(test_pid, {:on_enter, from, to})
              :ok
            end
          }
        )

      start_agent(config)
      assert_receive {:on_enter, :__init__, :ready}
    end

    test "on_enter and on_exit called on state transition" do
      test_pid = self()

      config =
        lifecycle_config(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{
              from: :a,
              to: :b,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: nil
            }
          ],
          on_enter: %{
            a: fn from, to -> send(test_pid, {:on_enter, from, to}) end,
            b: fn from, to -> send(test_pid, {:on_enter, from, to}) end
          },
          on_exit: %{
            a: fn from, to -> send(test_pid, {:on_exit, from, to}) end
          }
        )

      pid = start_agent(config)
      assert_receive {:on_enter, :__init__, :a}

      {:ok, _} = Agent.run(pid, "trigger")

      assert_receive {:on_exit, :a, :b}
      assert_receive {:on_enter, :a, :b}
    end
  end

  describe "multi-step state machine" do
    test "walks through multiple state transitions" do
      tool = echo_tool("advance")

      config =
        lifecycle_config(
          [
            initial_state: :step1,
            states: %{
              step1: %StateConfig{tools: [tool]},
              step2: %StateConfig{tools: [tool]},
              step3: %StateConfig{}
            },
            transitions: [
              %{from: :step1, to: :step2, trigger: {:tool_call, "advance"}, guard: nil},
              %{from: :step2, to: :step3, trigger: {:tool_call, "advance"}, guard: nil}
            ]
          ],
          provider_opts: [
            echo_mode: :function,
            echo_function: fn messages, _config ->
              # Check if the last message is a tool result — if so, return text
              last = List.last(messages)

              if last.role == :tool do
                {:ok, Message.assistant("Advanced")}
              else
                {:ok,
                 Message.assistant(nil, [
                   %Agora.ToolCall{
                     id: "tc_#{System.unique_integer([:positive])}",
                     name: "advance",
                     arguments: %{}
                   }
                 ])}
              end
            end
          ]
        )

      pid = start_agent(config)
      assert {:ok, :step1} = Agent.get_lifecycle_state(pid)

      {:ok, _} = Agent.run(pid, "go")
      assert {:ok, :step2} = Agent.get_lifecycle_state(pid)

      {:ok, _} = Agent.run(pid, "go again")
      assert {:ok, :step3} = Agent.get_lifecycle_state(pid)
    end
  end

  describe "transition telemetry" do
    test "emits state_transition telemetry event" do
      test_pid = self()
      unique = System.unique_integer([:positive])

      handler_id = "sm_telemetry_#{unique}"

      :telemetry.attach(
        handler_id,
        [:agora, :agent, :state_transition],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      config =
        lifecycle_config(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{
              from: :a,
              to: :b,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: nil
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "test")

      assert_receive {:telemetry, [:agora, :agent, :state_transition], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.from_state == :a
      assert metadata.to_state == :b

      :telemetry.detach(handler_id)
    end
  end

  describe "error handling" do
    test "provider errors don't trigger transitions" do
      config =
        lifecycle_config(
          [
            initial_state: :active,
            states: %{active: %StateConfig{}, done: %StateConfig{}},
            transitions: [
              %{
                from: :active,
                to: :done,
                trigger: {:message_match, fn _msg -> true end},
                guard: nil
              }
            ]
          ],
          provider_opts: [
            echo_mode: :error,
            echo_error_type: :provider_error,
            echo_error_message: "Test error"
          ]
        )

      pid = start_agent(config)
      {:error, error} = Agent.run(pid, "test")
      assert error.type == :provider_error

      # Should remain in :active
      assert {:ok, :active} = Agent.get_lifecycle_state(pid)
    end
  end

  describe "no :system messages in state machine history" do
    test "messages list has no system messages" do
      config =
        lifecycle_config(
          [
            initial_state: :active,
            states: %{
              active: %StateConfig{instructions: "Active instructions"}
            }
          ],
          instructions: "Base instructions"
        )

      pid = start_agent(config)
      messages = Agent.get_messages(pid)
      system_msgs = Enum.filter(messages, &(&1.role == :system))
      assert system_msgs == []

      {:ok, _} = Agent.run(pid, "Hello")
      messages = Agent.get_messages(pid)
      system_msgs = Enum.filter(messages, &(&1.role == :system))
      assert system_msgs == []
    end
  end

  describe "lifecycle validation in init" do
    test "rejects invalid lifecycle struct that bypasses new!/1" do
      # Manually build an invalid lifecycle (initial_state not in states)
      invalid_lifecycle = %Lifecycle{
        initial_state: :missing,
        states: %{ready: %StateConfig{}}
      }

      config = %{AgentConfig.new!(provider: :echo, model: "echo") | lifecycle: invalid_lifecycle}

      # gen_statem.start_link sends EXIT to caller on init failure; trap exits to get error tuple
      Process.flag(:trap_exit, true)

      assert {:error, error} = Agent.start_link(config: config)
      assert error.type == :config_error
      assert error.message =~ "Invalid lifecycle"
    after
      Process.flag(:trap_exit, false)
    end
  end

  describe "callback crash safety" do
    test "on_enter crash does not take down the process" do
      config =
        lifecycle_config(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{
              from: :a,
              to: :b,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: nil
            }
          ],
          on_enter: %{
            a: fn _from, _to -> :ok end,
            b: fn _from, _to -> raise "on_enter crash!" end
          }
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "trigger")

      # Agent should survive the callback crash and land in state :b
      assert {:ok, :b} = Agent.get_lifecycle_state(pid)
      assert Process.alive?(pid)
    end

    test "on_exit crash does not take down the process" do
      config =
        lifecycle_config(
          initial_state: :a,
          states: %{a: %StateConfig{}, b: %StateConfig{}},
          transitions: [
            %{
              from: :a,
              to: :b,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: nil
            }
          ],
          on_exit: %{
            a: fn _from, _to -> raise "on_exit crash!" end
          }
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "trigger")

      assert {:ok, :b} = Agent.get_lifecycle_state(pid)
      assert Process.alive?(pid)
    end

    test "guard crash returns false (skips transition)" do
      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}, done: %StateConfig{}},
          transitions: [
            %{
              from: :active,
              to: :done,
              trigger:
                {:message_match,
                 fn msg -> msg.content && String.contains?(msg.content, "Echo:") end},
              guard: fn _ctx -> raise "guard crash!" end
            }
          ]
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "test")

      # Guard crash => treated as false => no transition
      assert {:ok, :active} = Agent.get_lifecycle_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "memory" do
    test "clear_memory clears messages" do
      config =
        lifecycle_config(
          [
            initial_state: :active,
            states: %{active: %StateConfig{}}
          ],
          memory: {Agora.Memory.Buffer, max_messages: 50}
        )

      pid = start_agent(config)
      {:ok, _} = Agent.run(pid, "Hello")
      assert length(Agent.get_messages(pid)) > 0

      :ok = Agent.clear_memory(pid)
      assert Agent.get_messages(pid) == []
    end

    test "clear_memory errors when no memory configured" do
      config =
        lifecycle_config(
          initial_state: :active,
          states: %{active: %StateConfig{}}
        )

      pid = start_agent(config)
      {:error, error} = Agent.clear_memory(pid)
      assert error.type == :memory_error
    end
  end
end
