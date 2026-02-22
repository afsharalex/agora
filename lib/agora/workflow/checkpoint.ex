defmodule Agora.Workflow.Checkpoint do
  @moduledoc """
  First-class checkpoint object with metadata, compatibility checking,
  and lifecycle management.

  ## Workflow Hash

  `workflow_hash/1` computes a structural hash of the workflow topology.
  It detects step/edge additions, removals, and wiring changes but NOT
  handler logic changes — a bug fix in a handler function should still
  allow resuming from a previous checkpoint.

  ## OTP Compatibility

  The hash uses `:erlang.term_to_binary/1`, whose format is stable within
  an OTP major version but not guaranteed across major versions. The
  checkpoint stores `otp_major_version` at creation time, and
  `check_compatibility/2` includes this in error messages when hashes
  differ across OTP versions.
  """

  alias Agora.{Error, Workflow}

  @type status :: :in_progress | :completed | :failed | :abandoned

  @type t :: %__MODULE__{
          id: String.t(),
          workflow_hash: String.t(),
          version: pos_integer(),
          status: status(),
          results: %{atom() => term()},
          completed_steps: MapSet.t(atom()),
          pending_steps: MapSet.t(atom()),
          failed_steps: MapSet.t(atom()),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          otp_major_version: non_neg_integer(),
          metadata: map()
        }

  @derive {Jason.Encoder, except: [:completed_steps, :pending_steps, :failed_steps, :results]}
  defstruct [
    :id,
    :workflow_hash,
    :created_at,
    :updated_at,
    :otp_major_version,
    version: 1,
    status: :in_progress,
    results: %{},
    completed_steps: MapSet.new(),
    pending_steps: MapSet.new(),
    failed_steps: MapSet.new(),
    metadata: %{}
  ]

  @doc """
  Creates a new checkpoint for the given workflow.

  ## Options

    * `:id` — checkpoint ID (default: auto-generated)
    * `:metadata` — arbitrary metadata map (default: `%{}`)

  """
  @spec new(Workflow.t(), keyword()) :: t()
  def new(%Workflow{} = workflow, opts \\ []) do
    now = DateTime.utc_now()
    all_step_ids = Map.keys(workflow.steps) |> MapSet.new()

    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      workflow_hash: workflow_hash(workflow),
      version: 1,
      status: :in_progress,
      results: %{},
      completed_steps: MapSet.new(),
      pending_steps: all_step_ids,
      failed_steps: MapSet.new(),
      created_at: now,
      updated_at: now,
      otp_major_version: current_otp_major(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Generates a unique checkpoint ID.
  """
  @spec generate_id() :: String.t()
  def generate_id do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "chk_#{suffix}"
  end

  @doc """
  Computes a structural hash of a workflow topology.

  The hash captures step IDs, inputs, timeouts, retries, and edge structure
  (including whether conditions are present). Handler logic changes do not
  affect the hash — this allows resuming checkpoints after bug fixes.
  """
  @spec workflow_hash(Workflow.t()) :: String.t()
  def workflow_hash(%Workflow{steps: steps, edges: edges}) do
    step_data =
      steps
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, step} ->
        {id, Enum.sort(step.inputs), step.timeout, step.retry}
      end)

    edge_data =
      edges
      |> Enum.map(fn e -> {e.from, e.to, e.optional, e.condition != nil} end)
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({step_data, edge_data}))
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns true if the checkpoint is compatible with the given workflow.
  """
  @spec compatible?(t(), Workflow.t()) :: boolean()
  def compatible?(%__MODULE__{} = checkpoint, %Workflow{} = workflow) do
    checkpoint.workflow_hash == workflow_hash(workflow)
  end

  @doc """
  Checks compatibility between a checkpoint and a workflow.

  Returns `:ok` or `{:error, %Error{}}` with a detailed message including
  both hashes and OTP version information.
  """
  @spec check_compatibility(t(), Workflow.t()) :: :ok | {:error, Error.t()}
  def check_compatibility(%__MODULE__{} = checkpoint, %Workflow{} = workflow) do
    expected = workflow_hash(workflow)

    if checkpoint.workflow_hash == expected do
      :ok
    else
      current_otp = current_otp_major()

      otp_note =
        if checkpoint.otp_major_version != current_otp,
          do:
            " Note: checkpoint was created under OTP #{checkpoint.otp_major_version}, current is OTP #{current_otp}.",
          else: ""

      Error.wrap(
        :workflow_error,
        "Checkpoint hash mismatch (expected: #{expected}, got: #{checkpoint.workflow_hash}).#{otp_note}"
      )
    end
  end

  @doc """
  Updates the checkpoint with new step results after a level completes.

  Moves steps between pending/completed/failed sets based on outcomes
  and increments the version.
  """
  @spec record_level_results(t(), %{atom() => term()}) :: t()
  def record_level_results(%__MODULE__{} = checkpoint, level_results)
      when is_map(level_results) do
    now = DateTime.utc_now()

    {completed, failed, results} =
      Enum.reduce(
        level_results,
        {checkpoint.completed_steps, checkpoint.failed_steps, checkpoint.results},
        fn
          {step_id, {:ok, _} = result}, {comp, fail, res} ->
            {MapSet.put(comp, step_id), fail, Map.put(res, step_id, result)}

          {step_id, {:error, _} = result}, {comp, fail, res} ->
            {comp, MapSet.put(fail, step_id), Map.put(res, step_id, result)}

          {step_id, :skipped}, {comp, fail, res} ->
            {comp, fail, Map.put(res, step_id, :skipped)}
        end
      )

    all_done = MapSet.union(completed, failed)
    pending = MapSet.difference(checkpoint.pending_steps, all_done)
    # Also remove skipped steps from pending
    skipped_ids =
      level_results
      |> Enum.filter(fn {_k, v} -> v == :skipped end)
      |> Enum.map(fn {k, _v} -> k end)
      |> MapSet.new()

    pending = MapSet.difference(pending, skipped_ids)

    %{
      checkpoint
      | version: checkpoint.version + 1,
        results: results,
        completed_steps: completed,
        pending_steps: pending,
        failed_steps: failed,
        updated_at: now
    }
  end

  @doc """
  Finalizes the checkpoint with a terminal status.
  """
  @spec finalize(t(), :completed | :failed | :abandoned) :: t()
  def finalize(%__MODULE__{} = checkpoint, status)
      when status in [:completed, :failed, :abandoned] do
    %{
      checkpoint
      | status: status,
        version: checkpoint.version + 1,
        updated_at: DateTime.utc_now()
    }
  end

  # --- Management API ---

  @doc """
  Lists all checkpoints from a store.

  Accepts a store config tuple `{module, keyword()}`.
  """
  @spec list({module(), keyword()}) :: {:ok, [t()]} | {:error, Error.t()}
  def list({module, opts}) do
    alias Agora.Workflow.CheckpointStore

    with {:ok, cs} <- CheckpointStore.init({module, opts}) do
      CheckpointStore.list_snapshots(cs)
    end
  end

  @doc """
  Loads a specific checkpoint by ID and optional version.

  Accepts a store config tuple `{module, keyword()}`.
  """
  @spec load({module(), keyword()}, String.t(), pos_integer() | :latest) ::
          {:ok, t() | nil} | {:error, Error.t()}
  def load(store_config, checkpoint_id, version \\ :latest)

  def load({module, opts}, checkpoint_id, version) do
    alias Agora.Workflow.CheckpointStore

    with {:ok, cs} <- CheckpointStore.init({module, opts}) do
      CheckpointStore.load_snapshot(cs, checkpoint_id, version)
    end
  end

  @doc """
  Marks a checkpoint as abandoned (no longer resumable).
  """
  @spec abandon({module(), keyword()}, String.t()) :: :ok | {:error, Error.t()}
  def abandon({module, opts}, checkpoint_id) do
    alias Agora.Workflow.CheckpointStore

    with {:ok, cs} <- CheckpointStore.init({module, opts}),
         {:ok, checkpoint} <- CheckpointStore.load_snapshot(cs, checkpoint_id) do
      case checkpoint do
        nil ->
          :ok

        %__MODULE__{} = cp ->
          abandoned = finalize(cp, :abandoned)

          case CheckpointStore.save_snapshot(cs, abandoned) do
            {:ok, _} -> :ok
            {:error, _} = error -> error
          end
      end
    end
  end

  @doc """
  Deletes all snapshots for a checkpoint ID.
  """
  @spec delete({module(), keyword()}, String.t()) :: :ok | {:error, Error.t()}
  def delete({module, opts}, checkpoint_id) do
    alias Agora.Workflow.CheckpointStore

    with {:ok, cs} <- CheckpointStore.init({module, opts}) do
      # Delete all versions by loading and deleting each
      case CheckpointStore.load_snapshot(cs, checkpoint_id) do
        {:ok, nil} ->
          :ok

        {:ok, %__MODULE__{}} ->
          delete_all_versions(cs, checkpoint_id, 1)

        {:error, _} = error ->
          error
      end
    end
  end

  defp delete_all_versions(cs, checkpoint_id, version) do
    alias Agora.Workflow.CheckpointStore

    case CheckpointStore.delete_snapshot(cs, checkpoint_id, version) do
      {:ok, new_cs} ->
        # Try next version — stop when load returns nil
        case CheckpointStore.load_snapshot(new_cs, checkpoint_id) do
          {:ok, nil} -> :ok
          {:ok, _} -> delete_all_versions(new_cs, checkpoint_id, version + 1)
          {:error, _} -> :ok
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Applies a retention policy: keeps only recent completed checkpoints.

  ## Options

    * `:max_completed` — keep only the last N completed checkpoint runs
    * `:max_age` — TTL in seconds for completed checkpoints

  """
  @spec apply_retention({module(), keyword()}, keyword()) :: :ok | {:error, Error.t()}
  def apply_retention({module, opts}, retention_opts) do
    alias Agora.Workflow.CheckpointStore

    max_completed = Keyword.get(retention_opts, :max_completed)
    max_age = Keyword.get(retention_opts, :max_age)

    with {:ok, cs} <- CheckpointStore.init({module, opts}),
         {:ok, all} <- CheckpointStore.list_snapshots(cs) do
      completed =
        all
        |> Enum.filter(&(&1.status == :completed))
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

      to_delete = []

      # Apply max_completed
      to_delete =
        if max_completed && length(completed) > max_completed do
          expired = Enum.drop(completed, max_completed)
          to_delete ++ expired
        else
          to_delete
        end

      # Apply max_age
      to_delete =
        if max_age do
          now = DateTime.utc_now()

          aged =
            completed
            |> Enum.filter(fn cp ->
              DateTime.diff(now, cp.updated_at) > max_age
            end)

          (to_delete ++ aged) |> Enum.uniq_by(& &1.id)
        else
          to_delete
        end

      # Delete expired checkpoints (best-effort)
      Enum.each(to_delete, fn cp ->
        delete({module, opts}, cp.id)
      end)

      :ok
    end
  end

  defp current_otp_major do
    System.otp_release() |> String.to_integer()
  end
end
