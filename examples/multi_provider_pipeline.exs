# Multi-Provider Content Pipeline
#
# Chains a DAG workflow (parallel ideation + research) with an orchestrator
# loop (writer/reviewer) across Anthropic and OpenAI providers.
#
# Requires ANTHROPIC_API_KEY and OPENAI_API_KEY environment variables.
# Set AGORA_EXAMPLE_PROVIDER=echo to run without API keys.
#
# Run: mix run examples/multi_provider_pipeline.exs

alias Agora.{Message, Workflow.AgentStep, Workflow.Builder}
alias Agora.Orchestrator.TerminationCondition

# Suppress info-level telemetry warnings about anonymous handler functions
Logger.configure(level: :warning)

# --- Telemetry debug logging ---
# Attach handlers to see each workflow step and orchestrator turn in real time.

:telemetry.attach(
  "pipeline-workflow-step",
  [:agora, :workflow, :step, :stop],
  fn _event, %{duration: duration}, %{step_id: step_id}, _config ->
    ms = System.convert_time_unit(duration, :native, :millisecond)
    IO.puts("  [telemetry] workflow step :#{step_id} completed in #{ms}ms")
  end,
  nil
)

:telemetry.attach(
  "pipeline-orchestrator-step-start",
  [:agora, :orchestrator, :step, :start],
  fn _event, _measurements, %{agent: agent, step: step}, _config ->
    IO.puts("  [telemetry] orchestrator turn #{step} — running agent :#{agent}...")
  end,
  nil
)

:telemetry.attach(
  "pipeline-orchestrator-step-stop",
  [:agora, :orchestrator, :step, :stop],
  fn _event, %{duration: duration}, %{agent: agent, step: step}, _config ->
    ms = System.convert_time_unit(duration, :native, :millisecond)
    IO.puts("  [telemetry] orchestrator turn #{step} — :#{agent} responded in #{ms}ms")
  end,
  nil
)

# --- Provider selection ---

has_keys? =
  System.get_env("ANTHROPIC_API_KEY") not in [nil, ""] and
    System.get_env("OPENAI_API_KEY") not in [nil, ""]

use_echo? =
  System.get_env("AGORA_EXAMPLE_PROVIDER") == "echo" or not has_keys?

if use_echo? do
  IO.puts("[Using Echo provider — no API keys required]")
  unless has_keys?, do: IO.puts("  (Set ANTHROPIC_API_KEY and OPENAI_API_KEY to use real providers)")
  IO.puts("")
else
  IO.puts("[Using Anthropic + OpenAI providers]\n")
end

# Helper to build agent config with echo fallback
make_agent = fn name, provider, model, instructions, echo_opts ->
  if use_echo? do
    Agora.agent(:echo, "echo",
      name: name,
      instructions: instructions,
      provider_opts: echo_opts
    )
  else
    Agora.agent(provider, model,
      name: name,
      instructions: instructions
    )
  end
end

# --- Stage 1: DAG Workflow — Parallel Ideation + Research ---

IO.puts("=== Stage 1: Ideation + Research (DAG Workflow) ===\n")

domains = [
  "distributed systems",
  "machine learning",
  "developer tooling",
  "programming languages",
  "open source communities"
]

# 5 ideator agents (Anthropic) — each explores a different domain
ideator_configs =
  domains
  |> Enum.with_index(1)
  |> Enum.map(fn {domain, i} ->
    name = "ideator_#{i}"

    config = make_agent.(
      name,
      :anthropic,
      "claude-sonnet-4-20250514",
      "Generate one unique, specific article topic idea about #{domain}. " <>
        "Reply with just the topic idea in a single sentence. Be creative and specific.",
      [echo_mode: :static, echo_response: "Topic idea: How #{domain} is reshaping modern software engineering"]
    )

    id = String.to_atom("idea_#{i}")

    AgentStep.spec(id, config,
      input_mapper: fn _results -> "Generate a unique article topic idea about #{domain}." end
    )
  end)

# Researcher agent (OpenAI) — picks the best idea and researches it
idea_ids = Enum.map(1..5, &String.to_atom("idea_#{&1}"))

researcher = make_agent.(
  "researcher",
  :openai,
  "gpt-4o",
  "You are a research analyst. You will receive 5 topic ideas. " <>
    "Pick the most compelling one and produce a concise research brief with key facts, " <>
    "arguments, and structure for an article. Output just the research brief.",
  [echo_mode: :static, echo_response: "Research Brief: Distributed systems are reshaping modern software through event-driven architectures, the actor model, and CRDTs. Key points: 1) The actor model (Erlang/Elixir) enables fault-tolerant concurrency. 2) CRDTs solve distributed state without coordination. 3) Event sourcing provides audit trails and temporal queries."]
)

research_spec = AgentStep.spec(:research, researcher,
  inputs: idea_ids,
  input_mapper: fn results ->
    ideas =
      idea_ids
      |> Enum.map(fn id ->
        case results[id] do
          {:ok, msg} -> "- #{msg.content}"
          _ -> "- (no idea generated)"
        end
      end)
      |> Enum.join("\n")

    "Here are 5 article topic ideas:\n\n#{ideas}\n\nPick the best one and produce a research brief."
  end
)

# Build the DAG: 5 parallel ideators → researcher
workflow =
  Builder.new()
  |> then(fn builder ->
    Enum.reduce(ideator_configs, builder, &Builder.step(&2, &1))
  end)
  |> Builder.step(research_spec)
  |> Builder.build!()

{:ok, results} = Agora.run_workflow(workflow)

# Print ideation results
Enum.each(1..5, fn i ->
  id = String.to_atom("idea_#{i}")
  case results[id] do
    {:ok, msg} -> IO.puts("  [idea_#{i}] #{msg.content}")
    {:error, err} -> IO.puts("  [idea_#{i}] Error: #{inspect(err)}")
  end
end)

research_content =
  case results[:research] do
    {:ok, msg} ->
      IO.puts("\n  [research] #{msg.content}")
      msg.content

    {:error, err} ->
      IO.puts("\n  [research] Error: #{inspect(err)}")
      raise "Research step failed, cannot continue"
  end

# --- Stage 2: Orchestrator — Writer/Reviewer Loop ---

IO.puts("\n=== Stage 2: Writer/Reviewer Loop (Round-Robin) ===\n")

# Capture each agent's responses for logging and final output display.
# An Elixir Agent stores the latest output per agent name, since round_robin/3
# only returns the final message (the reviewer's APPROVED), not the writer's article.
{:ok, response_log} = Agent.start_link(fn -> %{} end)

# Middleware that prints each agent's full response as it happens
log_response = fn ctx, next ->
  case ctx.hook do
    :after_provider_call ->
      agent_name = ctx.config.name
      content = if ctx.response, do: ctx.response.content, else: "(no content)"
      IO.puts("  [#{agent_name}] #{content}\n")
      Agent.update(response_log, &Map.put(&1, agent_name, content))
      next.(ctx)

    _ ->
      next.(ctx)
  end
end

writer_config =
  if use_echo? do
    counter = :counters.new(1, [:atomics])

    writer_fn = fn _messages, _config ->
      n = :counters.get(counter, 1) + 1
      :counters.put(counter, 1, n)

      case n do
        1 ->
          {:ok, Message.assistant("Draft: Distributed systems have evolved from monolithic architectures to event-driven designs. The actor model, pioneered by Erlang, enables fault-tolerant concurrency through isolated processes and message passing.")}

        _ ->
          {:ok, Message.assistant("Revised article: Distributed systems have fundamentally reshaped software engineering. The actor model enables fault-tolerant concurrency, CRDTs solve distributed state without coordination, and event sourcing provides complete audit trails. These three pillars form the foundation of modern distributed architectures.")}
      end
    end

    Agora.agent(:echo, "echo",
      name: "writer",
      instructions: "You are a technical writer.",
      middleware: [log_response],
      provider_opts: [echo_mode: :function, echo_function: writer_fn]
    )
  else
    Agora.agent(:openai, "gpt-4o",
      name: "writer",
      middleware: [log_response],
      instructions: "You are a technical writer. Write a concise, engaging article based on the research provided. " <>
        "If you receive reviewer feedback, revise the article accordingly."
    )
  end

reviewer_config =
  if use_echo? do
    counter = :counters.new(1, [:atomics])

    reviewer_fn = fn _messages, _config ->
      n = :counters.get(counter, 1) + 1
      :counters.put(counter, 1, n)

      case n do
        1 ->
          {:ok, Message.assistant("The draft covers the actor model well but lacks depth on CRDTs and event sourcing. Please expand on these topics and add a stronger conclusion.")}

        _ ->
          {:ok, Message.assistant("APPROVED — the revised article is well-structured and covers all key topics from the research brief.")}
      end
    end

    Agora.agent(:echo, "echo",
      name: "reviewer",
      instructions: "You are a critical editor.",
      middleware: [log_response],
      provider_opts: [echo_mode: :function, echo_function: reviewer_fn]
    )
  else
    Agora.agent(:anthropic, "claude-sonnet-4-20250514",
      name: "reviewer",
      middleware: [log_response],
      instructions: "You are a critical editor. Review the article for accuracy, clarity, and completeness. " <>
        "If the article meets quality standards, start your response with APPROVED. " <>
        "Otherwise, provide specific feedback for revision."
    )
  end

{:ok, response} = Agora.round_robin(
  "Write an article based on this research:\n\n#{research_content}",
  [writer: writer_config, reviewer: reviewer_config],
  orchestrator_opts: [agent_order: [:writer, :reviewer]],
  termination: TerminationCondition.any_of([
    TerminationCondition.keyword_match(["APPROVED"]),
    TerminationCondition.max_turns(6)
  ])
)

last_responses = Agent.get(response_log, & &1)
Agent.stop(response_log)

IO.puts("\n=== Pipeline Complete ===")

IO.puts("\n--- Reviewer Verdict ---")
IO.puts(response.content)

IO.puts("--- Final Article (writer) ---")
IO.puts(last_responses["writer"] || "(no writer output captured)")

