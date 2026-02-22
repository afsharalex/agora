defmodule Agora.Workflow.DSL do
  @moduledoc """
  Block macro DSL for defining workflow DAGs.

  Provides a `workflow do ... end` macro that compiles to `Agora.Workflow.Builder`
  pipeline calls, eliminating pipe-threading ceremony for inline workflow definitions.

  ## Example

      import Agora.Workflow.DSL

      w = workflow do
        step :fetch do
          {:ok, MyApp.API.get_users()}
        end

        step :transform, after: :fetch do
          {:ok, users} = results[:fetch]
          {:ok, Enum.map(users, &normalize/1)}
        end

        step :count, after: :fetch, run: &count/1

        step :summary, run: &summarize/1

        [:count, :transform] ~> :summary
      end

  ## Workflow Options

  Options passed to `workflow` become `step_defaults` applied to all steps:

      w = workflow timeout: 30_000, retry: 1 do
        step :fetch, run: &fetch/1
      end

  ## Step Forms

  Steps can use a `do` block or `run:` keyword (not both):

      # do block — `results` binding available for accessing upstream results
      step :transform, after: :fetch do
        {:ok, data} = results[:fetch]
        {:ok, process(data)}
      end

      # run: keyword — pass a function reference directly
      step :transform, after: :fetch, run: &process/1

  ## Edge Wiring

  Three ways to declare edges:

      # Inline on step via after:
      step :b, after: :a, run: &b/1

      # Explicit edge declaration
      edge :a, :b, condition: fn r -> match?({:ok, _}, r[:a]) end

      # Visual wiring with ~>
      :a ~> :b ~> :c
      [:a, :b] ~> :c    # fan-in
      :a ~> [:b, :c]    # fan-out

  ## Topology Helpers

      chain [:a, :b, :c]                    # linear edges between pre-defined steps
      parallel [:b, :c], from: :a, to: :d   # fan-out/fan-in
  """

  alias Agora.Workflow.Builder

  @doc """
  Defines a workflow DAG using the block DSL.

  Accepts an optional keyword list of step defaults (`:timeout`, `:retry`)
  followed by a `do` block containing step, edge, chain, parallel, and `~>`
  declarations.

  Returns a `%Agora.Workflow{}` struct (calls `Builder.build!/1`).

  ## Examples

      w = workflow do
        step :a, run: fn _ -> {:ok, 1} end
        step :b, after: :a, run: fn r -> {:ok, elem(r[:a], 1) + 1} end
      end

      w = workflow timeout: 30_000 do
        step :a, run: fn _ -> {:ok, 1} end
      end
  """
  defmacro workflow(do: body) do
    compile_workflow([], body, __CALLER__)
  end

  defmacro workflow(opts, do: body) do
    compile_workflow(opts, body, __CALLER__)
  end

  # Stub macros for clear errors when used outside a `workflow` block.
  # These are safe because `do:` blocks are passed as quoted AST to the
  # outer `workflow` macro — inner macros don't expand before `workflow`
  # processes them.

  @outside_workflow_msg "can only be used inside a workflow do...end block"

  defmacro step(_id, _opts_or_block) do
    raise CompileError,
      line: __CALLER__.line,
      file: __CALLER__.file,
      description: "step #{@outside_workflow_msg}"
  end

  defmacro step(_id, _opts, _block) do
    raise CompileError,
      line: __CALLER__.line,
      file: __CALLER__.file,
      description: "step #{@outside_workflow_msg}"
  end

  defmacro edge(_from, _to) do
    raise CompileError,
      line: __CALLER__.line,
      file: __CALLER__.file,
      description: "edge #{@outside_workflow_msg}"
  end

  defmacro edge(_from, _to, _opts) do
    raise CompileError,
      line: __CALLER__.line,
      file: __CALLER__.file,
      description: "edge #{@outside_workflow_msg}"
  end

  defmacro chain(_ids) do
    raise CompileError,
      line: __CALLER__.line,
      file: __CALLER__.file,
      description: "chain #{@outside_workflow_msg}"
  end

  defmacro parallel(_ids, _opts) do
    raise CompileError,
      line: __CALLER__.line,
      file: __CALLER__.file,
      description: "parallel #{@outside_workflow_msg}"
  end

  # --- Compilation ---

  defp compile_workflow(opts, body, caller) do
    builder_var = Macro.unique_var(:builder, __MODULE__)
    statements = normalize_body(body)
    builder_calls = Enum.flat_map(statements, &classify_and_emit(&1, builder_var, caller))
    new_opts = if opts == [], do: [], else: [step_defaults: opts]

    quote do
      unquote(builder_var) = Builder.new(unquote(new_opts))
      unquote_splicing(builder_calls)
      Builder.build!(unquote(builder_var))
    end
  end

  defp normalize_body(nil), do: []
  defp normalize_body({:__block__, _, statements}), do: statements
  defp normalize_body(single), do: [single]

  # --- AST Classification ---

  # step :id do body end  →  {:step, meta, [id, [do: body]]}
  defp classify_and_emit({:step, meta, [id, [do: body]]}, bv, caller) do
    emit_step_do(id, [], body, bv, meta, caller)
  end

  # step :id, opts (possibly with do: merged in)
  defp classify_and_emit({:step, meta, [id, opts]}, bv, caller) when is_list(opts) do
    case Keyword.pop(opts, :do) do
      {nil, opts} -> emit_step_run(id, opts, bv, meta, caller)
      {body, opts} -> emit_step_do(id, opts, body, bv, meta, caller)
    end
  end

  # step :id, opts, [do: body]
  defp classify_and_emit({:step, meta, [id, opts, [do: body]]}, bv, caller)
       when is_list(opts) do
    emit_step_do(id, opts, body, bv, meta, caller)
  end

  # edge :from, :to
  defp classify_and_emit({:edge, _meta, [from, to]}, bv, _caller) do
    [emit_edge(from, to, [], bv)]
  end

  # edge :from, :to, opts
  defp classify_and_emit({:edge, meta, [from, to, opts]}, bv, caller) do
    [emit_edge(from, to, normalize_edge_opts(opts, meta, caller), bv)]
  end

  # chain [:a, :b, :c]
  defp classify_and_emit({:chain, _meta, [ids]}, bv, _caller) do
    [quote(do: unquote(bv) = Builder.sequence(unquote(bv), unquote(ids)))]
  end

  # parallel [:b, :c], from: :a, to: :d
  defp classify_and_emit({:parallel, _meta, [ids, opts]}, bv, _caller) do
    [quote(do: unquote(bv) = Builder.parallel(unquote(bv), unquote(ids), unquote(opts)))]
  end

  # ~> operator
  defp classify_and_emit({:~>, meta, _} = ast, bv, caller) do
    groups = flatten_pipe_groups(ast, meta, caller)
    emit_pipe_group_edges(groups, bv, meta, caller)
  end

  # Catch-all for unrecognized AST
  defp classify_and_emit(ast, _bv, caller) do
    raise CompileError,
      line: extract_line(ast),
      file: caller.file,
      description: "unexpected expression inside workflow block: #{Macro.to_string(ast)}"
  end

  # --- Step emission ---

  defp emit_step_do(id, opts, body, bv, meta, caller) do
    validate_no_run!(opts, meta, caller)

    param =
      if uses_results?(body),
        do: Macro.var(:results, nil),
        else: Macro.var(:_results, nil)

    handler = quote(do: fn unquote(param) -> unquote(body) end)
    remaining = Keyword.delete(opts, :run)

    [
      quote do
        unquote(bv) =
          Builder.step(unquote(bv), unquote(id), unquote(handler), unquote(remaining))
      end
    ]
  end

  defp emit_step_run(id, opts, bv, meta, caller) do
    case Keyword.pop(opts, :run) do
      {nil, _} ->
        raise CompileError,
          line: Keyword.get(meta, :line, 0),
          file: caller.file,
          description: "step #{inspect(id)} requires either a do block or run: option"

      {handler, remaining} ->
        [
          quote do
            unquote(bv) =
              Builder.step(unquote(bv), unquote(id), unquote(handler), unquote(remaining))
          end
        ]
    end
  end

  defp validate_no_run!(opts, meta, caller) do
    if Keyword.has_key?(opts, :run) do
      raise CompileError,
        line: Keyword.get(meta, :line, 0),
        file: caller.file,
        description: "step cannot have both a do block and run: option"
    end
  end

  # --- Edge emission ---

  defp emit_edge(from, to, opts, bv) do
    quote(do: unquote(bv) = Builder.edge(unquote(bv), unquote(from), unquote(to), unquote(opts)))
  end

  defp normalize_edge_opts(opts, meta, caller) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise CompileError,
        line: Keyword.get(meta, :line, 0),
        file: caller.file,
        description: "edge options must be a keyword list, got: #{inspect(opts)}"
    end

    has_condition = Keyword.has_key?(opts, :condition)
    has_when = Keyword.has_key?(opts, :when)

    cond do
      has_condition and has_when ->
        raise CompileError,
          line: Keyword.get(meta, :line, 0),
          file: caller.file,
          description: "edge cannot have both :condition and :when"

      has_when ->
        {when_fn, rest} = Keyword.pop!(opts, :when)
        Keyword.put(rest, :condition, when_fn)

      true ->
        opts
    end
    |> validate_optional_opt(meta, caller)
  end

  defp normalize_edge_opts(opts, meta, caller) do
    raise CompileError,
      line: Keyword.get(meta, :line, 0),
      file: caller.file,
      description: "edge options must be a keyword list, got: #{Macro.to_string(opts)}"
  end

  defp validate_optional_opt(opts, meta, caller) do
    case Keyword.fetch(opts, :optional) do
      :error ->
        opts

      {:ok, val} when is_boolean(val) ->
        opts

      {:ok, other} ->
        raise CompileError,
          line: Keyword.get(meta, :line, 0),
          file: caller.file,
          description: "edge :optional must be a boolean, got: #{inspect(other)}"
    end
  end

  # --- ~> pipe helpers ---

  defp flatten_pipe_groups({:~>, meta, [left, right]}, _outer_meta, caller) do
    flatten_pipe_groups(left, meta, caller) ++ [pipe_operand_to_group(right, meta, caller)]
  end

  defp flatten_pipe_groups(operand, meta, caller) do
    [pipe_operand_to_group(operand, meta, caller)]
  end

  defp pipe_operand_to_group(atom, _meta, _caller) when is_atom(atom), do: [atom]

  defp pipe_operand_to_group(list, meta, caller) when is_list(list) do
    Enum.each(list, fn
      a when is_atom(a) ->
        :ok

      other ->
        raise CompileError,
          line: Keyword.get(meta, :line, 0),
          file: caller.file,
          description: "~> list elements must be atoms, got: #{Macro.to_string(other)}"
    end)

    list
  end

  defp pipe_operand_to_group(other, meta, caller) do
    raise CompileError,
      line: Keyword.get(meta, :line, 0),
      file: caller.file,
      description: "~> operands must be atoms or lists of atoms, got: #{Macro.to_string(other)}"
  end

  defp emit_pipe_group_edges(groups, bv, meta, caller) do
    groups
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [left_group, right_group] ->
      if length(left_group) > 1 and length(right_group) > 1 do
        raise CompileError,
          line: Keyword.get(meta, :line, 0),
          file: caller.file,
          description:
            "~> does not support list-to-list (cross-product) wiring; " <>
              "use explicit edge declarations instead"
      end

      for from <- left_group, to <- right_group do
        emit_edge(from, to, [], bv)
      end
    end)
  end

  # --- Results detection ---

  defp uses_results?(ast), do: check_results_usage(ast)

  # For nested fn nodes, only skip clause bodies where params shadow `results`.
  # Closures that don't rebind `results` in their params capture it from the
  # outer scope, so we must detect usage there.
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

  # Pin operator is a reference to the outer binding, not a rebinding
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

  # --- Helpers ---

  defp extract_line({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp extract_line(_), do: 0
end
