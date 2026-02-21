defmodule Agora.Workflow.Builder do
  @moduledoc """
  DSL builder for constructing workflow DAGs.

  Provides a pipeline-friendly API for defining steps and edges, with
  validation at build time (cycle detection, endpoint verification).

  ## Example

      alias Agora.Workflow.Builder

      # Linear pipeline with chain/2
      workflow =
        Builder.new(step_defaults: [retry: 1])
        |> Builder.chain([
          {:fetch, &fetch_data/1},
          {:transform, &transform/1},
          {:load, &load/1, timeout: 5_000}
        ])
        |> Builder.build!()

      # Dependency declaration with after:
      workflow =
        Builder.new()
        |> Builder.step(:fetch, &fetch_data/1)
        |> Builder.step(:transform, &transform/1, after: :fetch)
        |> Builder.step(:load, &load/1, after: :transform)
        |> Builder.build!()

      # Inline conditional edge with condition:
      workflow =
        Builder.new()
        |> Builder.step(:check, &check_status/1)
        |> Builder.step(:notify, &send_alert/1,
          after: :check,
          condition: fn r -> elem(r[:check], 1) == :critical end
        )
        |> Builder.build!()

  ## Auto-Edge Generation

  Steps that declare `inputs: [:a, :b]` (or `after: [:a, :b]`) automatically
  generate edges `a -> step` and `b -> step` at build time, unless an explicit
  edge for that pair already exists. Explicit edges take precedence.

  """

  alias Agora.{Error, Workflow}
  alias Agora.Workflow.{Edge, Step}

  @type t :: %__MODULE__{
          steps: %{atom() => Step.t()},
          edges: [Edge.t()],
          errors: [Error.t()],
          step_defaults: keyword()
        }

  defstruct steps: %{}, edges: [], errors: [], step_defaults: []

  @allowed_step_defaults [:timeout, :retry]

  @doc """
  Creates a new empty builder.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new builder with options.

  ## Options

    * `:step_defaults` — keyword list of default options applied to all steps.
      Only `:timeout` and `:retry` are allowed. Per-step options override defaults.

  ## Examples

      Builder.new(step_defaults: [timeout: 30_000, retry: 2])

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    defaults = Keyword.get(opts, :step_defaults, [])

    case validate_step_defaults(defaults) do
      :ok -> %__MODULE__{step_defaults: defaults}
      {:error, error} -> %__MODULE__{errors: [error]}
    end
  end

  def new(_opts) do
    error = Error.new(:workflow_error, "Builder.new/1 expects a keyword list")
    %__MODULE__{errors: [error]}
  end

  @doc """
  Adds a step to the builder.

  ## Options

    * `:name` — human-readable name
    * `:inputs` — list of upstream step IDs (auto-generates edges)
    * `:after` — alias for `:inputs`. Accepts a single atom or list of atoms.
      Mutually exclusive with `:inputs`.
    * `:condition` — 1-arity function `(map() -> boolean())` for inline conditional
      edges. Requires exactly one dependency via `:after` or `:inputs`. For multiple
      dependencies, use `edge/4` instead.
    * `:when` — alias for `:condition`
    * `:outputs` — optional schema map (documentation only)
    * `:input_mapper` — `(map() -> String.t() | Message.t())` for AgentConfig handlers
    * `:timeout` — step timeout in ms (default: 300_000)
    * `:retry` — retry count (default: 0)

  """
  @spec step(t(), atom(), Step.handler(), keyword()) :: t()
  def step(%__MODULE__{} = builder, id, handler, opts \\ []) do
    if Map.has_key?(builder.steps, id) do
      error = Error.new(:workflow_error, "Step #{inspect(id)} already exists")
      %{builder | errors: [error | builder.errors]}
    else
      case normalize_step_opts(opts) do
        {:error, error} ->
          %{builder | errors: [error | builder.errors]}

        {:ok, cleaned_opts, condition_info} ->
          effective_opts = Keyword.merge(builder.step_defaults, cleaned_opts)

          case Step.new(Keyword.merge(effective_opts, id: id, handler: handler)) do
            {:ok, step} ->
              builder = %{builder | steps: Map.put(builder.steps, id, step)}
              maybe_add_condition_edge(builder, id, condition_info)

            {:error, error} ->
              %{builder | errors: [error | builder.errors]}
          end
      end
    end
  end

  @doc """
  Adds an explicit edge to the builder.

  ## Options

    * `:condition` — optional 1-arity function `(map() -> boolean())`

  """
  @spec edge(t(), atom(), atom(), keyword()) :: t()
  def edge(%__MODULE__{} = builder, from, to, opts \\ []) do
    case Edge.new(Keyword.merge(opts, from: from, to: to)) do
      {:ok, edge} ->
        add_edge(builder, edge)

      {:error, error} ->
        %{builder | errors: [error | builder.errors]}
    end
  end

  @doc """
  Chains a list of step IDs into a linear sequence of edges.

  Given `[:a, :b, :c]`, adds edges `a -> b` and `b -> c`.
  """
  @spec sequence(t(), [atom()]) :: t()
  def sequence(%__MODULE__{} = builder, step_ids) when is_list(step_ids) do
    pairs = Enum.chunk_every(step_ids, 2, 1, :discard)

    Enum.reduce(pairs, builder, fn [from, to], acc ->
      case Edge.new(from: from, to: to) do
        {:ok, edge} -> add_edge(acc, edge)
        {:error, error} -> %{acc | errors: [error | acc.errors]}
      end
    end)
  end

  @wiring_keys [:after, :inputs, :when, :condition]

  @doc """
  Defines a linear pipeline of steps and wires them in sequence.

  Each element is a `{id, handler}` or `{id, handler, opts}` tuple. Steps are
  registered via `step/4` and then chained via `sequence/2`. Wiring keys
  (`:after`, `:inputs`, `:when`, `:condition`) are not allowed in tuple opts
  since `chain/2` manages the edge topology.

  `step_defaults` from `Builder.new/1` are applied to each step.

  ## Examples

      Builder.new(step_defaults: [retry: 1])
      |> Builder.chain([
        {:fetch, &fetch/1},
        {:transform, &transform/1},
        {:load, &load/1, timeout: 5_000}
      ])

  """
  @spec chain(t(), [{atom(), Step.handler()} | {atom(), Step.handler(), keyword()}]) :: t()
  def chain(%__MODULE__{} = builder, tuples) when is_list(tuples) do
    {builder, ids} =
      Enum.reduce(tuples, {builder, []}, fn tuple, {acc, ids} ->
        case normalize_chain_tuple(tuple) do
          {:error, error} ->
            {%{acc | errors: [error | acc.errors]}, ids}

          {:ok, id, handler, opts} ->
            case validate_no_wiring_keys(opts) do
              {:error, error} ->
                {%{acc | errors: [error | acc.errors]}, ids}

              :ok ->
                errors_before = length(acc.errors)
                acc = step(acc, id, handler, opts)

                if length(acc.errors) == errors_before do
                  {acc, [id | ids]}
                else
                  {acc, ids}
                end
            end
        end
      end)

    sequence(builder, Enum.reverse(ids))
  end

  defp normalize_chain_tuple({id, handler}) when is_atom(id), do: {:ok, id, handler, []}

  defp normalize_chain_tuple({id, handler, opts}) when is_atom(id) and is_list(opts),
    do: {:ok, id, handler, opts}

  defp normalize_chain_tuple(other),
    do:
      {:error,
       Error.new(
         :workflow_error,
         "chain/2 expects {id, handler} or {id, handler, opts} tuples, got: #{inspect(other)}"
       )}

  defp validate_no_wiring_keys(opts) do
    if Keyword.keyword?(opts) do
      found = Keyword.keys(opts) |> Enum.filter(&(&1 in @wiring_keys))

      if found == [] do
        :ok
      else
        {:error,
         Error.new(
           :workflow_error,
           "chain/2 does not accept wiring options (#{inspect(found)})"
         )}
      end
    else
      {:error,
       Error.new(
         :workflow_error,
         "chain/2 expects step opts to be a keyword list, got: #{inspect(opts)}"
       )}
    end
  end

  @doc """
  Creates fan-out and/or fan-in edges for parallel execution.

  ## Options

    * `:from` — source step ID. Adds an edge from this step to each step in the list.
    * `:to` — sink step ID. Adds an edge from each step in the list to this step.

  At least one of `:from` or `:to` is required.

  ## Example

      builder
      |> Builder.parallel([:b, :c, :d], from: :a, to: :e)
      # Creates edges: a->b, a->c, a->d, b->e, c->e, d->e

  """
  @spec parallel(t(), [atom()], keyword()) :: t()
  def parallel(%__MODULE__{} = builder, step_ids, opts) when is_list(step_ids) do
    from = opts[:from]
    to = opts[:to]

    if is_nil(from) and is_nil(to) do
      error = Error.new(:workflow_error, "parallel/3 requires at least one of :from or :to")
      %{builder | errors: [error | builder.errors]}
    else
      builder = build_fan_edges(builder, step_ids, from, :fan_out)
      build_fan_edges(builder, step_ids, to, :fan_in)
    end
  end

  defp build_fan_edges(builder, _step_ids, nil, _direction), do: builder

  defp build_fan_edges(builder, step_ids, target, direction) do
    Enum.reduce(step_ids, builder, fn id, acc ->
      {from, to} =
        case direction do
          :fan_out -> {target, id}
          :fan_in -> {id, target}
        end

      case Edge.new(from: from, to: to) do
        {:ok, edge} -> add_edge(acc, edge)
        {:error, error} -> %{acc | errors: [error | acc.errors]}
      end
    end)
  end

  # --- Private: Step option normalization ---

  defp normalize_step_opts(opts) do
    has_after = Keyword.has_key?(opts, :after)
    has_inputs = Keyword.has_key?(opts, :inputs)
    has_condition = Keyword.has_key?(opts, :condition)
    has_when = Keyword.has_key?(opts, :when)

    with :ok <- validate_after_inputs_exclusive(has_after, has_inputs),
         :ok <- validate_condition_when_exclusive(has_condition, has_when),
         opts <- normalize_after_to_inputs(opts, has_after),
         {:ok, opts, condition_info} <- extract_condition(opts, has_condition or has_when) do
      {:ok, opts, condition_info}
    end
  end

  defp validate_after_inputs_exclusive(true, true),
    do: {:error, Error.new(:workflow_error, "Cannot specify both :after and :inputs")}

  defp validate_after_inputs_exclusive(_, _), do: :ok

  defp validate_condition_when_exclusive(true, true),
    do: {:error, Error.new(:workflow_error, "Cannot specify both :condition and :when")}

  defp validate_condition_when_exclusive(_, _), do: :ok

  defp normalize_after_to_inputs(opts, false), do: opts

  defp normalize_after_to_inputs(opts, true) do
    after_val = opts[:after]
    inputs = if is_atom(after_val), do: [after_val], else: after_val
    opts |> Keyword.delete(:after) |> Keyword.put(:inputs, inputs)
  end

  defp extract_condition(opts, false), do: {:ok, opts, nil}

  defp extract_condition(opts, true) do
    condition_fn =
      if Keyword.has_key?(opts, :condition), do: opts[:condition], else: opts[:when]

    inputs = opts[:inputs] || []

    cond do
      not is_list(inputs) ->
        {:error,
         Error.new(
           :workflow_error,
           ":condition/:when requires a single :after or :inputs dependency"
         )}

      inputs == [] ->
        {:error,
         Error.new(
           :workflow_error,
           ":condition/:when requires a single :after or :inputs dependency"
         )}

      length(inputs) > 1 ->
        {:error,
         Error.new(
           :workflow_error,
           ":condition/:when with multiple dependencies is not supported; use edge/4"
         )}

      true ->
        [from] = inputs
        cleaned = opts |> Keyword.delete(:condition) |> Keyword.delete(:when)
        {:ok, cleaned, {from, condition_fn}}
    end
  end

  defp maybe_add_condition_edge(builder, _id, nil), do: builder

  defp maybe_add_condition_edge(builder, id, {from, condition_fn}) do
    case Edge.new(from: from, to: id, condition: condition_fn) do
      {:ok, edge} -> add_edge(builder, edge)
      {:error, error} -> %{builder | errors: [error | builder.errors]}
    end
  end

  defp validate_step_defaults(defaults) when is_list(defaults) do
    if Keyword.keyword?(defaults) do
      unique_keys = defaults |> Keyword.keys() |> MapSet.new()
      allowed = MapSet.new(@allowed_step_defaults)
      invalid = MapSet.difference(unique_keys, allowed) |> MapSet.to_list()

      if invalid == [] do
        :ok
      else
        {:error,
         Error.new(
           :workflow_error,
           "step_defaults only accepts :timeout and :retry, got: #{inspect(invalid)}"
         )}
      end
    else
      {:error, Error.new(:workflow_error, "step_defaults must be a keyword list")}
    end
  end

  defp validate_step_defaults(_other) do
    {:error, Error.new(:workflow_error, "step_defaults must be a keyword list")}
  end

  defp add_edge(%__MODULE__{} = builder, %Edge{} = edge) do
    if edge_exists?(builder, edge.from, edge.to) do
      error =
        Error.new(
          :workflow_error,
          "Edge #{inspect(edge.from)} -> #{inspect(edge.to)} already exists"
        )

      %{builder | errors: [error | builder.errors]}
    else
      %{builder | edges: builder.edges ++ [edge]}
    end
  end

  defp edge_exists?(%__MODULE__{} = builder, from, to) do
    Enum.any?(builder.edges, fn e -> e.from == from and e.to == to end)
  end

  @doc """
  Validates the builder state and returns a `%Workflow{}`.

  Performs:
  1. Auto-edge generation from step `inputs` declarations
  2. All edge endpoints reference known step IDs
  3. All `inputs` references point to known step IDs
  4. No cycles (Kahn's algorithm)

  Returns `{:ok, %Workflow{}}` or `{:error, %Error{}}`.

  ## Options

    * `:skip_cycle_check` — when `true`, skips cycle validation. Used by
      `Agora.Workflow.Definition` when compile-time validation has already
      performed enhanced (conditional-aware) cycle detection. Default: `false`.

  """
  @spec build(t(), keyword()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def build(%__MODULE__{} = builder, opts \\ []) do
    with :ok <- check_errors(builder) do
      builder = merge_input_edges(builder)

      with :ok <- check_errors(builder),
           :ok <- validate_edge_endpoints(builder),
           :ok <- validate_input_refs(builder),
           :ok <- maybe_validate_cycles(builder, opts) do
        {:ok,
         %Workflow{
           steps: builder.steps,
           edges: builder.edges
         }}
      end
    end
  end

  defp check_errors(%{errors: []}), do: :ok

  defp check_errors(%{errors: errors}) do
    messages = errors |> Enum.reverse() |> Enum.map(& &1.message)
    Error.wrap(:workflow_error, "Builder errors: #{Enum.join(messages, "; ")}")
  end

  defp maybe_validate_cycles(builder, opts) do
    if Keyword.get(opts, :skip_cycle_check, false),
      do: :ok,
      else: validate_no_cycles(builder)
  end

  @doc """
  Validates and returns a `%Workflow{}`, raising on failure.

  Accepts the same options as `build/2`.
  """
  @spec build!(t(), keyword()) :: Workflow.t()
  def build!(%__MODULE__{} = builder, opts \\ []) do
    case build(builder, opts) do
      {:ok, workflow} -> workflow
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  # --- Private: Auto-edge generation from inputs ---

  defp merge_input_edges(builder) do
    explicit_pairs = MapSet.new(builder.edges, fn e -> {e.from, e.to} end)

    pairs =
      builder.steps
      |> Enum.flat_map(fn {step_id, step} ->
        Enum.map(step.inputs, fn input_id -> {input_id, step_id} end)
      end)
      |> Enum.reject(fn pair -> MapSet.member?(explicit_pairs, pair) end)

    # MapSet pre-filter above prevents explicit-vs-auto duplicates; add_edge/2
    # here is a defensive guard (auto-vs-auto duplicates can't occur by construction).
    Enum.reduce(pairs, builder, fn {from, to}, acc ->
      case Edge.new(from: from, to: to) do
        {:ok, edge} -> add_edge(acc, edge)
        {:error, error} -> %{acc | errors: [error | acc.errors]}
      end
    end)
  end

  # --- Private: Validation ---

  defp validate_edge_endpoints(builder) do
    known_ids = Map.keys(builder.steps) |> MapSet.new()

    invalid =
      Enum.flat_map(builder.edges, fn edge ->
        missing = []

        missing =
          if MapSet.member?(known_ids, edge.from), do: missing, else: [edge.from | missing]

        missing = if MapSet.member?(known_ids, edge.to), do: missing, else: [edge.to | missing]
        missing
      end)
      |> Enum.uniq()

    if invalid == [] do
      :ok
    else
      Error.wrap(
        :workflow_error,
        "Edges reference unknown step IDs: #{inspect(invalid)}"
      )
    end
  end

  defp validate_input_refs(builder) do
    known_ids = Map.keys(builder.steps) |> MapSet.new()

    invalid =
      builder.steps
      |> Enum.flat_map(fn {_id, step} -> step.inputs end)
      |> Enum.reject(fn id -> MapSet.member?(known_ids, id) end)
      |> Enum.uniq()

    if invalid == [] do
      :ok
    else
      Error.wrap(
        :workflow_error,
        "Step inputs reference unknown step IDs: #{inspect(invalid)}"
      )
    end
  end

  defp validate_no_cycles(builder) do
    # Kahn's algorithm for cycle detection
    step_ids = Map.keys(builder.steps)

    # Build adjacency list and in-degree count
    in_degree = Map.new(step_ids, fn id -> {id, 0} end)

    in_degree =
      Enum.reduce(builder.edges, in_degree, fn edge, acc ->
        Map.update!(acc, edge.to, &(&1 + 1))
      end)

    # Start with zero in-degree nodes
    queue = for {id, 0} <- in_degree, do: id
    {sorted_count, _in_degree} = topo_walk(queue, builder.edges, in_degree, 0)

    if sorted_count == length(step_ids) do
      :ok
    else
      Error.wrap(:workflow_error, "Workflow contains a cycle")
    end
  end

  defp topo_walk([], _edges, in_degree, count), do: {count, in_degree}

  defp topo_walk([node | rest], edges, in_degree, count) do
    # Find successors of this node
    successors =
      Enum.filter(edges, fn e -> e.from == node end)
      |> Enum.map(fn e -> e.to end)

    # Decrease in-degree for each successor
    {in_degree, new_queue} =
      Enum.reduce(successors, {in_degree, []}, fn succ, {deg, q} ->
        new_deg = Map.update!(deg, succ, &(&1 - 1))

        if Map.get(new_deg, succ) == 0 do
          {new_deg, [succ | q]}
        else
          {new_deg, q}
        end
      end)

    topo_walk(rest ++ new_queue, edges, in_degree, count + 1)
  end
end
