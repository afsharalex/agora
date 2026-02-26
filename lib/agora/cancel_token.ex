defmodule Agora.CancelToken do
  @moduledoc """
  Two-tier cancellation token for cross-process coordination.

  CancelToken provides both cooperative (soft) and immediate (hard) cancellation:

  - **Soft cancel** (`cancel/1`) — sets a flag checked at loop boundaries (before
    each iteration, before tool execution). Worker processes finish their current
    operation and exit cleanly at the next boundary.

  - **Hard kill** (`kill/1`) — sets both flags AND immediately kills all worker
    processes registered in the token's process group via `Process.exit(pid, :kill)`.
    Late joiners (processes that call `register/2` after `kill/1`) are auto-killed.

  ## Process Groups

  Worker processes (reasoning tasks, tool tasks, provider stream tasks) register
  themselves in the token's `:pg` group via `register/2`. This allows `kill/1` to
  find and terminate all associated workers without killing API-facing server
  processes (Agent GenServer, Runner GenServer).

  ## Design Constraints

  - Server processes are NEVER registered — only worker tasks.
  - `GenServer.call` sites always receive `{:error, %Error{type: :cancelled}}`,
    never an EXIT signal.
  - Cancellation is monotonic and idempotent — once cancelled/killed, the token
    stays in that state.

  ## Examples

      token = Agora.CancelToken.new()

      # Soft cancel
      Agora.CancelToken.cancel(token)
      Agora.CancelToken.cancelled?(token)  #=> true
      Agora.CancelToken.killed?(token)     #=> false

      # Hard kill
      token2 = Agora.CancelToken.new()
      Agora.CancelToken.register(token2, worker_pid)
      Agora.CancelToken.kill(token2)
      Agora.CancelToken.killed?(token2)    #=> true
      Agora.CancelToken.cancelled?(token2) #=> true  (kill implies cancel)

  """

  @pg_scope :agora_cancel_pg

  @type t :: %__MODULE__{ref: :atomics.atomics_ref()}

  defstruct [:ref]

  @doc """
  Creates a new uncancelled token.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{ref: :atomics.new(2, signed: false)}
  end

  @doc """
  Soft-cancels the token. Idempotent — safe to call multiple times.

  Sets the soft cancel flag (index 1). Does NOT set the hard kill flag
  or terminate any processes.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref}) do
    :atomics.put(ref, 1, 1)

    Agora.Telemetry.emit(
      [:agora, :cancel, :soft],
      %{system_time: System.system_time()},
      %{}
    )

    :ok
  end

  @doc """
  Returns `true` if the token has been soft-cancelled or hard-killed.
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{ref: ref}) do
    :atomics.get(ref, 1) == 1
  end

  @doc """
  Hard-kills: sets both flags, then kills all registered worker processes.

  Idempotent — safe to call multiple times. Processes registered after
  `kill/1` are auto-killed on registration.
  """
  @spec kill(t()) :: :ok
  def kill(%__MODULE__{ref: ref} = token) do
    :atomics.put(ref, 1, 1)
    :atomics.put(ref, 2, 1)
    killed_count = kill_process_group(token)

    Agora.Telemetry.emit(
      [:agora, :cancel, :kill],
      %{system_time: System.system_time()},
      %{group_size: killed_count}
    )

    :ok
  end

  @doc """
  Returns `true` if the token has been hard-killed.
  """
  @spec killed?(t()) :: boolean()
  def killed?(%__MODULE__{ref: ref}) do
    :atomics.get(ref, 2) == 1
  end

  @doc """
  Registers a worker process in the token's process group.

  If the token is already hard-killed, the process is immediately killed
  via `Process.exit(pid, :kill)`. This closes the race between spawn and
  register.

  Should be called from the PARENT process immediately after spawning the
  worker (not from inside the worker).
  """
  @spec register(t(), pid()) :: :ok
  def register(%__MODULE__{} = token, pid) when is_pid(pid) do
    group = group_name(token)
    :pg.join(@pg_scope, group, pid)

    # Auto-kill late joiners
    if killed?(token) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  @doc """
  Removes a worker process from the token's process group.

  Safe to call if the process is not a member. Should be called in
  `after` blocks for explicit cleanup.
  """
  @spec unregister(t(), pid()) :: :ok
  def unregister(%__MODULE__{} = token, pid) when is_pid(pid) do
    group = group_name(token)
    :pg.leave(@pg_scope, group, pid)
    :ok
  end

  @doc """
  Returns the `:pg` scope atom used by CancelToken.

  Useful for starting the `:pg` process in the supervision tree.
  """
  @spec pg_scope() :: atom()
  def pg_scope, do: @pg_scope

  # --- Private ---

  defp kill_process_group(%__MODULE__{} = token) do
    group = group_name(token)

    members =
      try do
        :pg.get_members(@pg_scope, group)
      catch
        # :pg scope not started or group doesn't exist
        :error, _ -> []
      end

    Enum.each(members, fn pid ->
      Process.exit(pid, :kill)
    end)

    length(members)
  end

  defp group_name(%__MODULE__{ref: ref}) do
    {__MODULE__, ref}
  end
end
