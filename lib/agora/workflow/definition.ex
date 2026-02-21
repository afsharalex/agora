defmodule Agora.Workflow.Definition do
  @moduledoc """
  Module-level DSL for defining reusable workflow modules.

  `use Agora.Workflow.Definition` sets up a module as a workflow definition,
  providing macros for declaring steps, edges, chains, and parallel topology.
  At compile time, the graph structure is validated and a `__workflow__/0`
  function is generated that returns a `%Agora.Workflow{}` struct.

  ## Example

      defmodule MyApp.Workflows.ETL do
        use Agora.Workflow.Definition,
          timeout: 30_000,
          retry: 1

        step :fetch do
          {:ok, MyApp.API.get_users()}
        end

        step :transform, after: :fetch do
          {:ok, users} = results[:fetch]
          {:ok, Enum.map(users, &normalize/1)}
        end

        step :store, after: :transform, retry: 3, run: &MyApp.DB.store/1

        edge :transform, :notify, condition: fn r ->
          match?({:ok, %{changed: true}}, r[:transform])
        end
      end

      # Usage
      {:ok, results} = Agora.run_workflow(MyApp.Workflows.ETL)

  ## Use Options

  Options passed to `use` become `step_defaults` applied to all steps:

    * `:timeout` — default step timeout in ms
    * `:retry` — default retry count

  ## Step Forms

  Steps can use a `do` block or `run:` keyword (not both):

      # do block — `results` binding available for accessing upstream results
      step :transform, after: :fetch do
        {:ok, data} = results[:fetch]
        {:ok, process(data)}
      end

      # run: keyword — pass a function reference directly
      step :store, after: :transform, run: &MyApp.DB.store/1

  ## Generated Functions

    * `__workflow__/0` — returns a `%Agora.Workflow{}` struct
    * `__workflow_steps__/0` — returns step IDs in definition order

  ## Step Testing

  Step functions generated from `do` blocks are public (with `@doc false`)
  and can be tested in isolation:

      results = %{fetch: {:ok, ["Alice", "Bob"]}}
      assert {:ok, 2} = MyApp.Workflows.ETL.__agora_step_count__(results)

  Steps defined with `run:` do not generate named functions.
  """

  alias Agora.Workflow.Builder

  @allowed_use_opts [:timeout, :retry]

  defmacro __using__(opts) do
    {opts, _} = Code.eval_quoted(opts, [], __CALLER__)

    unless Keyword.keyword?(opts) do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "use Agora.Workflow.Definition expects a keyword list, got: #{inspect(opts)}"
    end

    invalid = Keyword.keys(opts) -- @allowed_use_opts

    if invalid != [] do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description:
          "use Agora.Workflow.Definition only accepts :timeout and :retry, " <>
            "got: #{inspect(invalid)}"
    end

    quote do
      import Agora.Workflow.Definition,
        only: [step: 2, step: 3, edge: 2, edge: 3, chain: 1, parallel: 2]

      Module.register_attribute(__MODULE__, :__agora_steps__, accumulate: true)
      Module.register_attribute(__MODULE__, :__agora_edges__, accumulate: true)
      Module.register_attribute(__MODULE__, :__agora_sequences__, accumulate: true)
      Module.register_attribute(__MODULE__, :__agora_parallels__, accumulate: true)
      @__agora_step_defaults__ unquote(opts)

      @before_compile Agora.Workflow.Definition
    end
  end

  # --- Step macro ---

  @doc """
  Defines a workflow step with a `do` block handler.

  The block receives a `results` binding containing upstream step results.
  Generates a public function `__agora_step_<id>__/1` with `@doc false`.

  ## Examples

      step :fetch do
        {:ok, get_data()}
      end

      step :transform, after: :fetch do
        {:ok, data} = results[:fetch]
        {:ok, process(data)}
      end

  """
  defmacro step(id, do: body) do
    emit_step(id, [], body, __CALLER__)
  end

  defmacro step(id, opts) do
    if Keyword.keyword?(opts) do
      case Keyword.pop(opts, :do) do
        {nil, opts} ->
          emit_step_run(id, opts, __CALLER__)

        {body, opts} ->
          emit_step(id, opts, body, __CALLER__)
      end
    else
      # opts might be [do: body] from `step :id do ... end` with no extra opts
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "step options must be a keyword list"
    end
  end

  @doc """
  Defines a workflow step with options and a `do` block handler.

  ## Examples

      step :transform, after: :fetch, timeout: 5_000 do
        {:ok, data} = results[:fetch]
        {:ok, process(data)}
      end

  """
  defmacro step(id, opts, do: body) do
    emit_step(id, opts, body, __CALLER__)
  end

  defp emit_step(id, opts, body, caller) do
    validate_no_run!(id, opts, caller)

    fn_name = step_fn_name(id)

    param =
      if check_results_usage(body),
        do: Macro.var(:results, nil),
        else: Macro.var(:_results, nil)

    escaped_opts = Macro.escape(opts)

    quote do
      @doc false
      def unquote(fn_name)(unquote(param)) do
        unquote(body)
      end

      @__agora_steps__ {unquote(id), unquote(escaped_opts), :do_block}
    end
  end

  defp emit_step_run(id, opts, caller) do
    case Keyword.pop(opts, :run) do
      {nil, _} ->
        raise CompileError,
          line: caller.line,
          file: caller.file,
          description: "step #{inspect(id)} requires either a do block or run: option"

      {handler, remaining} ->
        escaped_remaining = Macro.escape(remaining)
        escaped_handler = Macro.escape(handler)

        quote do
          @__agora_steps__ {unquote(id), unquote(escaped_remaining),
                            {:run, unquote(escaped_handler)}}
        end
    end
  end

  defp validate_no_run!(id, opts, caller) do
    if Keyword.has_key?(opts, :run) do
      raise CompileError,
        line: caller.line,
        file: caller.file,
        description: "step #{inspect(id)} cannot have both a do block and run: option"
    end
  end

  defp step_fn_name(id) do
    :"__agora_step_#{id}__"
  end

  # --- Edge macro ---

  @doc """
  Declares an explicit edge between two steps.

  ## Options

    * `:condition` — optional 1-arity function `(map() -> boolean())`
    * `:when` — alias for `:condition`

  ## Examples

      edge :fetch, :transform

      edge :check, :notify, condition: fn r ->
        r[:check] == {:ok, :critical}
      end

  """
  defmacro edge(from, to) do
    quote do
      @__agora_edges__ {unquote(from), unquote(to), []}
    end
  end

  defmacro edge(from, to, opts) do
    normalized = normalize_edge_opts(opts, __CALLER__)
    escaped = Macro.escape(normalized)

    quote do
      @__agora_edges__ {unquote(from), unquote(to), unquote(escaped)}
    end
  end

  defp normalize_edge_opts(opts, caller) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise CompileError,
        line: caller.line,
        file: caller.file,
        description: "edge options must be a keyword list, got: #{inspect(opts)}"
    end

    has_condition = Keyword.has_key?(opts, :condition)
    has_when = Keyword.has_key?(opts, :when)

    cond do
      has_condition and has_when ->
        raise CompileError,
          line: caller.line,
          file: caller.file,
          description: "edge cannot have both :condition and :when"

      has_when ->
        {when_fn, rest} = Keyword.pop!(opts, :when)
        Keyword.put(rest, :condition, when_fn)

      true ->
        opts
    end
    |> validate_optional_opt(caller)
  end

  defp normalize_edge_opts(opts, caller) do
    raise CompileError,
      line: caller.line,
      file: caller.file,
      description: "edge options must be a keyword list, got: #{Macro.to_string(opts)}"
  end

  defp validate_optional_opt(opts, caller) do
    case Keyword.fetch(opts, :optional) do
      :error ->
        opts

      {:ok, val} when is_boolean(val) ->
        opts

      {:ok, other} ->
        raise CompileError,
          line: caller.line,
          file: caller.file,
          description: "edge :optional must be a boolean, got: #{inspect(other)}"
    end
  end

  # --- Chain macro ---

  @doc """
  Chains a list of step IDs into a linear sequence of edges.

  Steps must be defined separately. This macro only creates edges.

  ## Examples

      chain [:fetch, :transform, :load]

  """
  defmacro chain(ids) do
    quote do
      @__agora_sequences__ unquote(ids)
    end
  end

  # --- Parallel macro ---

  @doc """
  Creates fan-out and/or fan-in edges for parallel execution.

  ## Options

    * `:from` — source step ID
    * `:to` — sink step ID

  ## Examples

      parallel [:b, :c], from: :a, to: :d

  """
  defmacro parallel(ids, opts) do
    escaped = Macro.escape(opts)

    quote do
      @__agora_parallels__ {unquote(ids), unquote(escaped)}
    end
  end

  # --- @before_compile ---

  defmacro __before_compile__(env) do
    steps = Module.get_attribute(env.module, :__agora_steps__) |> Enum.reverse()
    edges = Module.get_attribute(env.module, :__agora_edges__) |> Enum.reverse()
    sequences = Module.get_attribute(env.module, :__agora_sequences__) |> Enum.reverse()
    parallels = Module.get_attribute(env.module, :__agora_parallels__) |> Enum.reverse()
    step_defaults = Module.get_attribute(env.module, :__agora_step_defaults__)

    # --- Compile-time validation ---
    step_ids = Enum.map(steps, fn {id, _opts, _handler} -> id end)
    known_ids = MapSet.new(step_ids)

    validate_unique_steps!(step_ids, env)
    validate_inputs_format!(steps, env)
    validate_step_conditions!(steps, env)
    validate_parallel_opts!(parallels, env)
    all_edges = resolve_all_edges(steps, edges, sequences, parallels, env)
    validate_endpoints!(all_edges, known_ids, env)
    validate_no_self_loops!(all_edges, env)
    validate_input_refs!(steps, known_ids, env)
    has_conditional_cycles = validate_cycles!(all_edges, known_ids, env)

    # --- Code generation ---
    step_calls = generate_step_calls(steps, env)
    edge_calls = generate_edge_calls(edges)
    sequence_calls = generate_sequence_calls(sequences)
    parallel_calls = generate_parallel_calls(parallels)

    build_opts = if has_conditional_cycles, do: [skip_cycle_check: true], else: []

    quote do
      @doc false
      def __workflow__ do
        builder = Builder.new(step_defaults: unquote(step_defaults))
        unquote_splicing(step_calls)
        unquote_splicing(edge_calls)
        unquote_splicing(sequence_calls)
        unquote_splicing(parallel_calls)
        Builder.build!(builder, unquote(build_opts))
      end

      @doc false
      def __workflow_steps__ do
        unquote(step_ids)
      end
    end
  end

  # --- Compile-time validation helpers ---

  defp validate_unique_steps!(step_ids, env) do
    step_ids
    |> Enum.reduce(MapSet.new(), fn id, seen ->
      if MapSet.member?(seen, id) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "duplicate step ID #{inspect(id)} in workflow definition"
      end

      MapSet.put(seen, id)
    end)
  end

  defp validate_inputs_format!(steps, env) do
    Enum.each(steps, fn {step_id, opts, _handler} ->
      opts = eval_opts_for_validation(opts)

      if Keyword.has_key?(opts, :inputs) do
        inputs = opts[:inputs]

        cond do
          not is_list(inputs) ->
            raise CompileError,
              file: env.file,
              line: env.line,
              description:
                "step #{inspect(step_id)} :inputs must be a list of atoms, " <>
                  "got: #{inspect(inputs)}. Use :after for a single dependency"

          not Enum.all?(inputs, &is_atom/1) ->
            raise CompileError,
              file: env.file,
              line: env.line,
              description:
                "step #{inspect(step_id)} :inputs must be a list of atoms, " <>
                  "got: #{inspect(inputs)}"

          true ->
            :ok
        end
      end
    end)
  end

  defp validate_parallel_opts!(parallels, env) do
    Enum.each(parallels, fn {_ids, opts} ->
      if Keyword.keyword?(opts) do
        has_from = Keyword.has_key?(opts, :from)
        has_to = Keyword.has_key?(opts, :to)

        unless has_from or has_to do
          raise CompileError,
            file: env.file,
            line: env.line,
            description: "parallel/2 requires at least one of :from or :to"
        end
      else
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "parallel/2 options must be a keyword list, got: #{inspect(opts)}"
      end
    end)
  end

  defp validate_step_conditions!(steps, env) do
    Enum.each(steps, fn {step_id, opts, _handler} ->
      opts = eval_opts_for_validation(opts)

      has_condition = Keyword.has_key?(opts, :condition)
      has_when = Keyword.has_key?(opts, :when)

      if has_condition and has_when do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "step #{inspect(step_id)} cannot have both :condition and :when"
      end

      if has_condition or has_when do
        inputs = resolve_inputs(opts)

        if inputs == [] do
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "step #{inspect(step_id)} has :condition/:when but no :after or :inputs dependency"
        end

        if length(inputs) > 1 do
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "step #{inspect(step_id)} has :condition/:when with multiple dependencies; use edge/3 instead"
        end
      end
    end)
  end

  defp resolve_all_edges(steps, edges, sequences, parallels, _env) do
    # 1. Explicit edges
    explicit =
      Enum.map(edges, fn {from, to, opts} ->
        {from, to, Keyword.has_key?(opts, :condition)}
      end)

    # 2. Auto-edges from step after:/inputs: and condition:/when:
    auto =
      Enum.flat_map(steps, fn {step_id, opts_ast, _handler} ->
        opts = eval_opts_for_validation(opts_ast)
        resolve_step_auto_edges(step_id, opts)
      end)

    # 3. Sequence edges
    seq =
      Enum.flat_map(sequences, fn ids ->
        ids
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] -> {from, to, false} end)
      end)

    # 4. Parallel edges
    par =
      Enum.flat_map(parallels, fn {ids, opts} ->
        from = Keyword.get(opts, :from)
        to = Keyword.get(opts, :to)

        fan_out = if from, do: Enum.map(ids, &{from, &1, false}), else: []
        fan_in = if to, do: Enum.map(ids, &{&1, to, false}), else: []
        fan_out ++ fan_in
      end)

    explicit ++ auto ++ seq ++ par
  end

  defp eval_opts_for_validation(opts_ast) when is_list(opts_ast) do
    # At compile time the opts AST stored in attributes has been through
    # Macro.escape then unquoted. For simple keyword lists (atoms, integers,
    # lists of atoms) the result is plain Elixir terms.  Function values
    # (condition:, run:, when:) are already evaluated or are AST — we only
    # need the key names and atom/list values for dependency analysis.
    opts_ast
  end

  defp eval_opts_for_validation(_), do: []

  defp resolve_step_auto_edges(step_id, opts) do
    # Normalize after: → inputs:
    inputs = resolve_inputs(opts)

    # Check for condition:/when:
    has_condition = Keyword.has_key?(opts, :condition) or Keyword.has_key?(opts, :when)

    if has_condition and length(inputs) == 1 do
      # Single-dep conditional — generates a conditional edge
      [from] = inputs
      [{from, step_id, true}]
    else
      # Regular auto-edges (unconditional)
      Enum.map(inputs, fn input -> {input, step_id, false} end)
    end
  end

  defp resolve_inputs(opts) do
    raw =
      cond do
        Keyword.has_key?(opts, :after) ->
          after_val = opts[:after]
          if is_atom(after_val), do: [after_val], else: after_val

        Keyword.has_key?(opts, :inputs) ->
          opts[:inputs]

        true ->
          []
      end

    # Guard: always return a list even if user passes inputs: :atom
    if is_list(raw), do: raw, else: [raw]
  end

  defp validate_endpoints!(edges, known_ids, env) do
    unknown =
      edges
      |> Enum.flat_map(fn {from, to, _} ->
        missing = []
        missing = if MapSet.member?(known_ids, from), do: missing, else: [from | missing]
        missing = if MapSet.member?(known_ids, to), do: missing, else: [to | missing]
        missing
      end)
      |> Enum.uniq()

    if unknown != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "edges reference unknown step IDs: #{inspect(unknown)}"
    end
  end

  defp validate_no_self_loops!(edges, env) do
    Enum.each(edges, fn {from, to, _} ->
      if from == to do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "edge cannot be a self-loop: #{inspect(from)} -> #{inspect(to)}"
      end
    end)
  end

  defp validate_input_refs!(steps, known_ids, env) do
    unknown =
      steps
      |> Enum.flat_map(fn {_id, opts, _handler} ->
        resolve_inputs(opts)
      end)
      |> Enum.reject(&MapSet.member?(known_ids, &1))
      |> Enum.uniq()

    if unknown != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "step inputs reference unknown step IDs: #{inspect(unknown)}"
    end
  end

  defp validate_cycles!(edges, known_ids, env) do
    # Pass 1: Unconditional edges only — cycle is always a compile error
    unconditional = Enum.filter(edges, fn {_, _, cond?} -> not cond? end)
    unconditional_pairs = Enum.map(unconditional, fn {from, to, _} -> {from, to} end)

    if has_cycle?(unconditional_pairs, known_ids) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "workflow contains a cycle (unconditional edges)"
    end

    # Pass 2: All edges — cycle is a warning (conditional edges may break it)
    all_pairs = Enum.map(edges, fn {from, to, _} -> {from, to} end)

    if has_cycle?(all_pairs, known_ids) do
      IO.warn(
        "workflow contains a potential cycle involving conditional edges — " <>
          "this may cause runtime errors if conditions don't break the cycle",
        Macro.Env.stacktrace(env)
      )

      true
    else
      false
    end
  end

  defp has_cycle?(edge_pairs, known_ids) do
    step_ids = MapSet.to_list(known_ids)
    in_degree = Map.new(step_ids, fn id -> {id, 0} end)

    in_degree =
      Enum.reduce(edge_pairs, in_degree, fn {_from, to}, acc ->
        Map.update(acc, to, 1, &(&1 + 1))
      end)

    queue = for {id, 0} <- in_degree, do: id
    sorted_count = topo_walk(queue, edge_pairs, in_degree, 0)

    sorted_count != length(step_ids)
  end

  defp topo_walk([], _edges, _in_degree, count), do: count

  defp topo_walk([node | rest], edges, in_degree, count) do
    successors =
      edges
      |> Enum.filter(fn {from, _to} -> from == node end)
      |> Enum.map(fn {_from, to} -> to end)

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

  # --- Code generation helpers ---

  defp generate_step_calls(steps, _env) do
    Enum.map(steps, fn {id, opts_ast, handler_form} ->
      handler_ast =
        case handler_form do
          :do_block ->
            fn_name = step_fn_name(id)

            quote do
              Function.capture(__MODULE__, unquote(fn_name), 1)
            end

          {:run, handler} ->
            handler
        end

      quote do
        builder = Builder.step(builder, unquote(id), unquote(handler_ast), unquote(opts_ast))
      end
    end)
  end

  defp generate_edge_calls(edges) do
    Enum.map(edges, fn {from, to, opts_ast} ->
      quote do
        builder = Builder.edge(builder, unquote(from), unquote(to), unquote(opts_ast))
      end
    end)
  end

  defp generate_sequence_calls(sequences) do
    Enum.map(sequences, fn ids ->
      quote do
        builder = Builder.sequence(builder, unquote(ids))
      end
    end)
  end

  defp generate_parallel_calls(parallels) do
    Enum.map(parallels, fn {ids, opts_ast} ->
      quote do
        builder = Builder.parallel(builder, unquote(ids), unquote(opts_ast))
      end
    end)
  end

  # --- Results detection (duplicated from DSL to avoid coupling) ---

  defp check_results_usage({:fn, _, clauses}) when is_list(clauses) do
    Enum.any?(clauses, fn
      {:->, _, [params, body]} ->
        if params_shadow_results?(params), do: false, else: check_results_usage(body)

      other ->
        check_results_usage(other)
    end)
  end

  defp check_results_usage({:results, _, ctx}) when is_atom(ctx), do: true

  defp check_results_usage({_form, _meta, args}) when is_list(args) do
    Enum.any?(args, &check_results_usage/1)
  end

  defp check_results_usage(list) when is_list(list) do
    Enum.any?(list, &check_results_usage/1)
  end

  defp check_results_usage({left, right}) do
    check_results_usage(left) or check_results_usage(right)
  end

  defp check_results_usage(_), do: false

  defp params_shadow_results?(params) when is_list(params) do
    Enum.any?(params, &pattern_contains_results?/1)
  end

  defp pattern_contains_results?({:results, _, ctx}) when is_atom(ctx), do: true
  defp pattern_contains_results?({:^, _, _}), do: false

  defp pattern_contains_results?({_form, _meta, args}) when is_list(args) do
    Enum.any?(args, &pattern_contains_results?/1)
  end

  defp pattern_contains_results?(list) when is_list(list) do
    Enum.any?(list, &pattern_contains_results?/1)
  end

  defp pattern_contains_results?({left, right}) do
    pattern_contains_results?(left) or pattern_contains_results?(right)
  end

  defp pattern_contains_results?(_), do: false
end
