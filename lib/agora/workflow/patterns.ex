defmodule Agora.Workflow.Patterns do
  @moduledoc """
  Convenience pattern builders for common workflow topologies.

  Each function constructs a `%Workflow{}` struct from a concise specification,
  wrapping `Agora.Workflow.Builder` primitives.

  ## Step Specs

  Step specs are tuples describing a step:

      {id, handler}               # minimal
      {id, handler, opts}         # with options (timeout, retry, etc.)

  Where `id` is an atom, `handler` is a 1-arity function or `AgentConfig`,
  and `opts` is a keyword list of step options.

  ## Examples

      # Linear chain
      {:ok, workflow} = Patterns.sequential([
        {:fetch, &fetch/1},
        {:transform, &transform/1},
        {:load, &load/1, timeout: 5_000}
      ])

      # Fan-out/fan-in
      {:ok, workflow} = Patterns.parallel(
        [{:b, &work_b/1}, {:c, &work_c/1}],
        from: {:a, &source/1},
        to: {:d, &sink/1}
      )

      # Conditional routing
      {:ok, workflow} = Patterns.conditional(
        {:router, &check/1},
        [
          {fn r -> r[:router] == {:ok, :a} end, {:branch_a, &handle_a/1}},
          {fn r -> r[:router] == {:ok, :b} end, {:branch_b, &handle_b/1}}
        ],
        merge: {:final, &merge/1}
      )

  """

  alias Agora.{Error, Workflow}
  alias Agora.Workflow.Builder

  @type step_spec ::
          {atom(), Workflow.Step.handler()} | {atom(), Workflow.Step.handler(), keyword()}
  @type branch_spec :: {(map() -> boolean()), step_spec()}

  @doc """
  Builds a linear chain workflow: A → B → C.

  ## Options

    * `:step_defaults` — keyword list applied to all steps

  """
  @spec sequential([step_spec()], keyword()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def sequential(steps, opts \\ [])

  def sequential(steps, opts) when is_list(steps) and length(steps) > 0 do
    step_defaults = Keyword.get(opts, :step_defaults, [])
    builder_opts = if step_defaults == [], do: [], else: [step_defaults: step_defaults]

    with :ok <- validate_step_specs(steps, "sequential") do
      tuples = Enum.map(steps, &normalize_step_spec/1)
      builder = Builder.new(builder_opts) |> Builder.chain(tuples)
      Builder.build(builder)
    end
  end

  def sequential([], _opts) do
    Error.wrap(:workflow_error, "sequential/2 requires a non-empty list of step specs")
  end

  def sequential(other, _opts) do
    Error.wrap(
      :workflow_error,
      "sequential/2 expects a list of step specs, got: #{inspect(other)}"
    )
  end

  @doc """
  Builds a linear chain workflow, raising on failure.
  """
  @spec sequential!([step_spec()], keyword()) :: Workflow.t()
  def sequential!(steps, opts \\ []) do
    case sequential(steps, opts) do
      {:ok, workflow} -> workflow
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  @doc """
  Builds a fan-out/fan-in workflow.

  ## Options

    * `:from` — source step spec. Adds edges from this step to each branch.
    * `:to` — sink step spec. Adds edges from each branch to this step.
    * `:step_defaults` — keyword list applied to all steps

  When `:from` and/or `:to` are provided, they are full step specs that
  this function creates. They are NOT IDs referencing pre-existing steps.

  """
  @spec parallel([step_spec()], keyword()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def parallel(branches, opts \\ [])

  def parallel(branches, opts) when is_list(branches) and length(branches) > 0 do
    step_defaults = Keyword.get(opts, :step_defaults, [])
    from_spec = Keyword.get(opts, :from)
    to_spec = Keyword.get(opts, :to)
    builder_opts = if step_defaults == [], do: [], else: [step_defaults: step_defaults]

    with :ok <- validate_step_specs(branches, "parallel"),
         :ok <- validate_optional_spec(from_spec, ":from"),
         :ok <- validate_optional_spec(to_spec, ":to") do
      builder = Builder.new(builder_opts)

      # Add from step if provided
      {builder, from_id} =
        case from_spec do
          nil -> {builder, nil}
          spec -> add_step_spec(builder, spec)
        end

      # Add branch steps
      {builder, branch_ids} =
        Enum.reduce(branches, {builder, []}, fn spec, {b, ids} ->
          {b, id} = add_step_spec(b, spec)
          {b, [id | ids]}
        end)

      branch_ids = Enum.reverse(branch_ids)

      # Add to step if provided
      {builder, to_id} =
        case to_spec do
          nil -> {builder, nil}
          spec -> add_step_spec(builder, spec)
        end

      # Wire edges
      builder =
        if from_id do
          Builder.parallel(builder, branch_ids, from: from_id, to: to_id)
        else
          if to_id do
            Builder.parallel(builder, branch_ids, to: to_id)
          else
            builder
          end
        end

      Builder.build(builder)
    end
  end

  def parallel([], _opts) do
    Error.wrap(:workflow_error, "parallel/2 requires a non-empty list of step specs")
  end

  def parallel(other, _opts) do
    Error.wrap(:workflow_error, "parallel/2 expects a list of step specs, got: #{inspect(other)}")
  end

  @doc """
  Builds a fan-out/fan-in workflow, raising on failure.
  """
  @spec parallel!([step_spec()], keyword()) :: Workflow.t()
  def parallel!(branches, opts \\ []) do
    case parallel(branches, opts) do
      {:ok, workflow} -> workflow
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  @doc """
  Builds a conditional routing workflow.

  A router step feeds into conditional branches. Each branch has a condition
  function that determines whether it runs based on the router's result.

  ## Options

    * `:merge` — optional merge step spec. Branches connect to the merge step
      with `optional: true` edges, so the merge runs even when some branches
      are skipped (but NOT when they fail).
    * `:step_defaults` — keyword list applied to all steps

  """
  @spec conditional(step_spec(), [branch_spec()], keyword()) ::
          {:ok, Workflow.t()} | {:error, Error.t()}
  def conditional(router, branches, opts \\ [])

  def conditional(router, branches, opts)
      when is_list(branches) and length(branches) > 0 do
    step_defaults = Keyword.get(opts, :step_defaults, [])
    merge_spec = Keyword.get(opts, :merge)
    builder_opts = if step_defaults == [], do: [], else: [step_defaults: step_defaults]

    with :ok <- validate_step_spec(router, "conditional router"),
         :ok <- validate_branch_specs(branches),
         :ok <- validate_optional_spec(merge_spec, ":merge") do
      builder = Builder.new(builder_opts)

      # Add router step
      {builder, router_id} = add_step_spec(builder, router)

      # Add branch steps with conditional edges from router
      {builder, branch_ids} =
        Enum.reduce(branches, {builder, []}, fn {condition_fn, spec}, {b, ids} ->
          {b, branch_id} = add_step_spec(b, spec)
          b = Builder.edge(b, router_id, branch_id, condition: condition_fn)
          {b, [branch_id | ids]}
        end)

      branch_ids = Enum.reverse(branch_ids)

      # Add optional merge step if provided
      builder =
        case merge_spec do
          nil ->
            builder

          spec ->
            {builder, merge_id} = add_step_spec(builder, spec)

            Enum.reduce(branch_ids, builder, fn branch_id, b ->
              Builder.edge(b, branch_id, merge_id, optional: true)
            end)
        end

      Builder.build(builder)
    end
  end

  def conditional(_router, [], _opts) do
    Error.wrap(:workflow_error, "conditional/3 requires a non-empty list of branch specs")
  end

  def conditional(_router, other, _opts) when not is_list(other) do
    Error.wrap(
      :workflow_error,
      "conditional/3 expects a list of branch specs, got: #{inspect(other)}"
    )
  end

  @doc """
  Builds a conditional routing workflow, raising on failure.
  """
  @spec conditional!(step_spec(), [branch_spec()], keyword()) :: Workflow.t()
  def conditional!(router, branches, opts \\ []) do
    case conditional(router, branches, opts) do
      {:ok, workflow} -> workflow
      {:error, error} -> raise ArgumentError, to_string(error)
    end
  end

  # --- Private helpers ---

  defp add_step_spec(builder, {id, handler}) do
    {Builder.step(builder, id, handler), id}
  end

  defp add_step_spec(builder, {id, handler, opts}) do
    {Builder.step(builder, id, handler, opts), id}
  end

  defp normalize_step_spec({id, handler}), do: {id, handler}
  defp normalize_step_spec({id, handler, opts}), do: {id, handler, opts}

  defp validate_step_specs(specs, context) do
    invalid =
      Enum.reject(specs, fn
        {id, handler} when is_atom(id) and (is_function(handler, 1) or is_struct(handler)) ->
          true

        {id, handler, opts}
        when is_atom(id) and (is_function(handler, 1) or is_struct(handler)) and is_list(opts) ->
          true

        _ ->
          false
      end)

    if invalid == [] do
      :ok
    else
      Error.wrap(
        :workflow_error,
        "#{context}/2 received invalid step specs: #{inspect(invalid)}. " <>
          "Expected {id, handler} or {id, handler, opts} tuples."
      )
    end
  end

  defp validate_step_spec(spec, context) do
    case spec do
      {id, handler} when is_atom(id) and (is_function(handler, 1) or is_struct(handler)) ->
        :ok

      {id, handler, opts}
      when is_atom(id) and (is_function(handler, 1) or is_struct(handler)) and is_list(opts) ->
        :ok

      _ ->
        Error.wrap(
          :workflow_error,
          "#{context} expects a step spec {id, handler} or {id, handler, opts}, " <>
            "got: #{inspect(spec)}"
        )
    end
  end

  defp validate_optional_spec(nil, _label), do: :ok

  defp validate_optional_spec(spec, label) do
    case spec do
      {id, handler} when is_atom(id) and (is_function(handler, 1) or is_struct(handler)) ->
        :ok

      {id, handler, opts}
      when is_atom(id) and (is_function(handler, 1) or is_struct(handler)) and is_list(opts) ->
        :ok

      _ ->
        Error.wrap(
          :workflow_error,
          "#{label} expects a step spec {id, handler} or {id, handler, opts}, " <>
            "got: #{inspect(spec)}"
        )
    end
  end

  defp validate_branch_specs(branches) do
    invalid =
      Enum.reject(branches, fn
        {condition, spec}
        when is_function(condition, 1) ->
          match?({id, _handler} when is_atom(id), spec) or
            match?({id, _handler, opts} when is_atom(id) and is_list(opts), spec)

        _ ->
          false
      end)

    if invalid == [] do
      :ok
    else
      Error.wrap(
        :workflow_error,
        "conditional/3 received invalid branch specs: #{inspect(invalid)}. " <>
          "Expected {condition_fn, step_spec} tuples."
      )
    end
  end
end
