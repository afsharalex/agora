defmodule Agora.Stream do
  @moduledoc """
  Enumerable wrapper for consuming streaming events from an agent or orchestration execution.

  Wraps the process-based streaming protocol into an `Enumerable` so callers
  can use standard `Enum` and `Stream` operations:

      {:ok, stream} = Agora.Agent.stream_run(agent, "Hello")

      stream
      |> Stream.filter(&(&1.type == :text_delta))
      |> Enum.each(fn event -> IO.write(event.data.text) end)

  ## Ownership

  Streams are bound to the process that initiated `stream_run/2`. Attempting
  to enumerate from a different process raises `ArgumentError`.

  ## Termination

  Every stream is guaranteed to terminate. The Enumerable receives events
  until either a `:done` or `:error` event arrives, the streaming process
  crashes (detected via monitor), or a safety timeout (300s) expires.

  ## Event Types

  Supports both `StreamEvent` (LLM-level) and `ModeEvent` (orchestration-level)
  events. Terminal detection uses map pattern matching (`%{type: :done}` /
  `%{type: :error}`) to work with both event types.
  """

  @type t :: %__MODULE__{
          ref: reference(),
          pid: pid(),
          owner: pid(),
          error_fn: (Agora.Error.t() -> term()) | nil
        }

  defstruct [:ref, :pid, :owner, :error_fn]

  @doc """
  Creates a new stream handle.

  ## Options

    * `:error_fn` — function to create error events for `:DOWN` and timeout
      scenarios. Defaults to `&StreamEvent.error/1`. Pass `&ModeEvent.error/1`
      for orchestration-level streams.
  """
  @spec new(reference(), pid(), pid(), keyword()) :: t()
  def new(ref, pid, owner \\ self(), opts \\ []) do
    %__MODULE__{
      ref: ref,
      pid: pid,
      owner: owner,
      error_fn: Keyword.get(opts, :error_fn)
    }
  end

  defimpl Enumerable do
    alias Agora.{Error, StreamEvent}

    @stream_timeout 300_000

    def count(_stream), do: {:error, __MODULE__}
    def member?(_stream, _element), do: {:error, __MODULE__}
    def slice(_stream), do: {:error, __MODULE__}

    def reduce(%Agora.Stream{} = stream, acc, fun) do
      if self() != stream.owner do
        raise ArgumentError,
              "Agora.Stream can only be enumerated by the owner process " <>
                "(owner: #{inspect(stream.owner)}, current: #{inspect(self())})"
      end

      mref = Process.monitor(stream.pid)
      result = do_reduce(stream.ref, stream.pid, mref, stream.error_fn, acc, fun)
      Process.demonitor(mref, [:flush])
      result
    end

    defp do_reduce(_ref, _pid, _mref, _error_fn, {:halt, acc}, _fun) do
      {:halted, acc}
    end

    defp do_reduce(ref, pid, mref, error_fn, {:suspend, acc}, fun) do
      {:suspended, acc, &do_reduce(ref, pid, mref, error_fn, &1, fun)}
    end

    defp do_reduce(ref, pid, mref, error_fn, {:cont, acc}, fun) do
      receive do
        {Agora.Stream, ^ref, %{type: :done} = event} ->
          case fun.(event, acc) do
            {:halt, acc} -> {:halted, acc}
            {_, acc} -> {:done, acc}
          end

        {Agora.Stream, ^ref, %{type: :error} = event} ->
          case fun.(event, acc) do
            {:halt, acc} -> {:halted, acc}
            {_, acc} -> {:done, acc}
          end

        {Agora.Stream, ^ref, event} ->
          do_reduce(ref, pid, mref, error_fn, fun.(event, acc), fun)

        {:DOWN, ^mref, :process, ^pid, reason} ->
          error = Error.new(:streaming_error, "Stream process crashed: #{inspect(reason)}")
          error_event = make_error(error_fn, error)

          case fun.(error_event, acc) do
            {:halt, acc} -> {:halted, acc}
            {_, acc} -> {:done, acc}
          end
      after
        @stream_timeout ->
          error = Error.new(:timeout, "Stream timed out after #{@stream_timeout}ms")
          error_event = make_error(error_fn, error)

          case fun.(error_event, acc) do
            {:halt, acc} -> {:halted, acc}
            {_, acc} -> {:done, acc}
          end
      end
    end

    defp make_error(nil, error), do: StreamEvent.error(error)
    defp make_error(fun, error), do: fun.(error)
  end
end
