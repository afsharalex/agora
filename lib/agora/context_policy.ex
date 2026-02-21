defmodule Agora.ContextPolicy do
  @moduledoc """
  Compaction strategy for conversation message history.

  ContextPolicy is a pure function that trims messages before they are sent
  to a provider, preventing unbounded token growth in long-running agents
  and orchestrations.

  ## Strategies

    * `:none` — passthrough, no compaction
    * `:head_tail` — keep first `:head` + last `:tail` non-system messages
    * `:sliding_window` — keep last `:window_size` non-system messages
    * `:summary` — call `:summarize_fn` on discarded messages, insert synthetic summary

  ## Invariants

  The following rules are never violated:

  1. The latest user message is always preserved (current turn input)
  2. Assistant tool-call + tool-result message pairs are kept intact
  3. System messages are exempt from compaction when `:keep_system` is true
  4. When discarding, oldest non-system, non-tool-pair messages go first
  5. Retained messages preserve their original relative ordering

  ## Example

      policy = Agora.ContextPolicy.new!(strategy: :sliding_window, window_size: 20)
      compacted = Agora.ContextPolicy.apply(policy, messages)

  """

  @type strategy :: :none | :head_tail | :sliding_window | :summary
  @type t :: %__MODULE__{strategy: strategy(), opts: keyword()}

  defstruct [:strategy, opts: []]

  @valid_strategies [:none, :head_tail, :sliding_window, :summary]

  @doc """
  Creates a validated ContextPolicy.

  ## Options

    * `:strategy` (required) — one of #{inspect(@valid_strategies)}
    * `:head` — number of head messages to keep (`:head_tail`, default 2)
    * `:tail` — number of tail messages to keep (`:head_tail`, default 10)
    * `:window_size` — sliding window size (`:sliding_window`, default 20)
    * `:summarize_fn` — 1-arity function for `:summary` strategy
    * `:keep_system` — preserve system messages (default `true`)

  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    strategy = Keyword.fetch!(opts, :strategy)

    unless strategy in @valid_strategies do
      raise ArgumentError,
            "invalid strategy #{inspect(strategy)}, must be one of #{inspect(@valid_strategies)}"
    end

    validate_strategy_opts!(strategy, opts)

    %__MODULE__{strategy: strategy, opts: Keyword.delete(opts, :strategy)}
  end

  @doc """
  Applies the compaction policy to a list of messages.

  Returns a compacted list preserving all invariants, including original
  relative ordering of retained messages.
  """
  @spec apply(t(), [Agora.Message.t()]) :: [Agora.Message.t()]
  def apply(%__MODULE__{strategy: :none}, messages), do: messages

  def apply(%__MODULE__{strategy: :head_tail, opts: opts}, messages) do
    head_count = Keyword.get(opts, :head, 2)
    tail_count = Keyword.get(opts, :tail, 10)
    keep_system = Keyword.get(opts, :keep_system, true)

    indexed = index_messages(messages)
    {system_indices, non_system} = partition_system(indexed, keep_system)

    protected = protect_tool_pairs(non_system)
    surviving = head_tail_select(protected, head_count, tail_count)

    reconstruct(messages, system_indices, surviving)
    |> ensure_latest_user(messages)
  end

  def apply(%__MODULE__{strategy: :sliding_window, opts: opts}, messages) do
    window_size = Keyword.get(opts, :window_size, 20)
    keep_system = Keyword.get(opts, :keep_system, true)

    indexed = index_messages(messages)
    {system_indices, non_system} = partition_system(indexed, keep_system)

    protected = protect_tool_pairs(non_system)
    surviving = sliding_window_select(protected, window_size)

    reconstruct(messages, system_indices, surviving)
    |> ensure_latest_user(messages)
  end

  def apply(%__MODULE__{strategy: :summary, opts: opts}, messages) do
    window_size = Keyword.get(opts, :window_size, 20)
    summarize_fn = Keyword.fetch!(opts, :summarize_fn)
    keep_system = Keyword.get(opts, :keep_system, true)

    indexed = index_messages(messages)
    {system_indices, non_system} = partition_system(indexed, keep_system)

    if length(non_system) <= window_size do
      messages
    else
      {to_discard_indexed, to_keep_indexed} =
        Enum.split(non_system, length(non_system) - window_size)

      # Repair tool pairs that may have been split at the boundary
      to_keep_indexed = repair_tool_pairs_indexed(to_keep_indexed, non_system)

      to_discard_msgs = Enum.map(to_discard_indexed, fn {_i, msg} -> msg end)
      summary_text = summarize_fn.(to_discard_msgs)
      summary_msg = Agora.Message.new(:user, summary_text, metadata: %{synthetic: true})

      surviving_indices = MapSet.new(to_keep_indexed, fn {i, _msg} -> i end)

      # Insert summary before the first surviving non-system message
      base = reconstruct(messages, system_indices, surviving_indices)

      insert_summary(base, summary_msg, surviving_indices, messages)
      |> ensure_latest_user(messages)
    end
  end

  # --- Private: Validation ---

  defp validate_strategy_opts!(:head_tail, opts) do
    validate_pos_integer_opt!(opts, :head)
    validate_pos_integer_opt!(opts, :tail)
  end

  defp validate_strategy_opts!(:sliding_window, opts) do
    validate_pos_integer_opt!(opts, :window_size)
  end

  defp validate_strategy_opts!(:summary, opts) do
    unless Keyword.has_key?(opts, :summarize_fn) do
      raise ArgumentError, ":summary strategy requires a :summarize_fn option"
    end

    fn_val = Keyword.get(opts, :summarize_fn)

    unless is_function(fn_val, 1) do
      raise ArgumentError, ":summarize_fn must be a 1-arity function"
    end

    validate_pos_integer_opt!(opts, :window_size)
  end

  defp validate_strategy_opts!(_strategy, _opts), do: :ok

  defp validate_pos_integer_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_integer(val) and val > 0 ->
        :ok

      {:ok, val} ->
        raise ArgumentError, ":#{key} must be a positive integer, got: #{inspect(val)}"

      :error ->
        :ok
    end
  end

  # --- Private: Indexing ---

  # Tag each message with its original position index
  defp index_messages(messages) do
    Enum.with_index(messages, fn msg, i -> {i, msg} end)
  end

  # Partition into system indices (MapSet) and non-system indexed list.
  # System messages are exempt from compaction when keep_system is true.
  defp partition_system(indexed, true) do
    {system, non_system} =
      Enum.split_with(indexed, fn {_i, msg} -> msg.role == :system end)

    system_indices = MapSet.new(system, fn {i, _msg} -> i end)
    {system_indices, non_system}
  end

  defp partition_system(indexed, false) do
    {MapSet.new(), indexed}
  end

  # --- Private: Tool pair protection ---

  # Mark tool-call/result pairs so they stay together.
  # Returns list of {:single, {idx, msg}} | {:pair, [{idx, msg}, {idx, msg}]}
  defp protect_tool_pairs(indexed_msgs) do
    protect_tool_pairs(indexed_msgs, [])
  end

  defp protect_tool_pairs([], acc), do: Enum.reverse(acc)

  defp protect_tool_pairs([{i, %{role: :assistant, tool_calls: tc} = msg} | rest], acc)
       when tc != [] do
    case rest do
      [{j, %{role: :tool} = tool_msg} | rest2] ->
        protect_tool_pairs(rest2, [{:pair, [{i, msg}, {j, tool_msg}]} | acc])

      _ ->
        protect_tool_pairs(rest, [{:single, {i, msg}} | acc])
    end
  end

  defp protect_tool_pairs([indexed_msg | rest], acc) do
    protect_tool_pairs(rest, [{:single, indexed_msg} | acc])
  end

  # --- Private: Selection strategies ---

  # head_tail: keep first `head` + last `tail` protected entries
  # Returns MapSet of surviving original indices
  defp head_tail_select(protected, head_count, tail_count) do
    total = length(protected)

    selected =
      if total <= head_count + tail_count do
        protected
      else
        Enum.take(protected, head_count) ++ Enum.take(protected, -tail_count)
      end

    indices_from_protected(selected)
  end

  # sliding_window: keep last `window_size` protected entries
  # Returns MapSet of surviving original indices
  defp sliding_window_select(protected, window_size) do
    selected =
      if length(protected) <= window_size do
        protected
      else
        Enum.take(protected, -window_size)
      end

    indices_from_protected(selected)
  end

  # Extract original indices from protected entries
  defp indices_from_protected(entries) do
    Enum.reduce(entries, MapSet.new(), fn
      {:single, {i, _msg}}, acc -> MapSet.put(acc, i)
      {:pair, pairs}, acc -> Enum.reduce(pairs, acc, fn {i, _msg}, a -> MapSet.put(a, i) end)
    end)
  end

  # --- Private: Reconstruction ---

  # Walk the original message list in order, emitting only messages whose
  # indices are in system_indices or surviving_indices. This preserves the
  # original relative ordering of all retained messages.
  defp reconstruct(messages, system_indices, surviving_indices) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {_msg, i} ->
      MapSet.member?(system_indices, i) or MapSet.member?(surviving_indices, i)
    end)
    |> Enum.map(fn {msg, _i} -> msg end)
  end

  # Insert summary message before the first surviving non-system message
  defp insert_summary(result, summary_msg, surviving_indices, original) do
    # Find where the first surviving non-system message is in the result
    first_surviving_idx =
      original
      |> Enum.with_index()
      |> Enum.find_value(fn {_msg, i} ->
        if MapSet.member?(surviving_indices, i), do: i
      end)

    case first_surviving_idx do
      nil ->
        result ++ [summary_msg]

      target_idx ->
        pos =
          Enum.find_index(result, fn msg ->
            msg.created_at == Enum.at(original, target_idx).created_at
          end)

        if pos do
          List.insert_at(result, pos, summary_msg)
        else
          result ++ [summary_msg]
        end
    end
  end

  # Ensure the latest user message is present in the result
  defp ensure_latest_user(result, original) do
    latest_user = original |> Enum.reverse() |> Enum.find(&(&1.role == :user))

    case latest_user do
      nil ->
        result

      msg ->
        if Enum.any?(result, fn r -> r.created_at == msg.created_at end) do
          result
        else
          result ++ [msg]
        end
    end
  end

  # Repair tool pairs that may have been split at the boundary (summary strategy)
  defp repair_tool_pairs_indexed(to_keep, all_non_system) do
    case to_keep do
      [{_j, %{role: :tool}} = tool_entry | rest] ->
        {j, _tool_msg} = tool_entry
        # Find what precedes this in the full non-system list
        ns_idx = Enum.find_index(all_non_system, fn {i, _m} -> i == j end)

        if ns_idx && ns_idx > 0 do
          {prev_i, prev_msg} = Enum.at(all_non_system, ns_idx - 1)

          if prev_msg.role == :assistant && prev_msg.tool_calls != [] do
            [{prev_i, prev_msg}, tool_entry | rest]
          else
            to_keep
          end
        else
          to_keep
        end

      _ ->
        to_keep
    end
  end
end
