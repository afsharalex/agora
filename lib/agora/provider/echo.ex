defmodule Agora.Provider.Echo do
  @moduledoc """
  Echo provider for testing and development.

  Returns predictable responses based on a configurable mode, set via
  `config.provider_opts[:echo_mode]`. Defaults to `:echo`.

  ## Modes

    * `:echo` — echoes the last user message content
    * `:static` — returns a fixed response from `:echo_response`
    * `:tool_call` — returns an assistant message with tool calls from `:echo_tool_calls`
    * `:sequence` — returns the Nth response from `:echo_responses` based on conversation
    * `:error` — returns an error from `:echo_error_type` and `:echo_error_message`
    * `:function` — calls a 2-arity function from `:echo_function`

  """

  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Error, Message, Provider, StreamEvent, ToolCall}

  @doc "Returns a predictable response based on the configured echo mode."
  @spec chat([Message.t()], AgentConfig.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  @impl true
  def chat(messages, %AgentConfig{} = config) do
    mode = Provider.get_provider_opt(config, :echo_mode, :echo)
    handle_mode(mode, messages, config)
  end

  @doc "Starts streaming events based on the configured echo mode."
  @spec stream_chat([Message.t()], AgentConfig.t()) ::
          {:ok, %{pid: pid(), ref: reference()}} | {:error, Error.t()}
  @impl true
  def stream_chat(messages, %AgentConfig{} = config) do
    caller = self()
    ref = make_ref()
    mode = Provider.get_provider_opt(config, :echo_mode, :echo)

    {:ok, pid} =
      Task.Supervisor.start_child(Agora.StreamSupervisor, fn ->
        handle_stream_mode(mode, messages, config, caller, ref)
      end)

    {:ok, %{pid: pid, ref: ref}}
  end

  defp handle_mode(:echo, messages, _config) do
    content =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: :user, content: content} when is_binary(content) -> content
        _ -> nil
      end)

    {:ok, Message.assistant("Echo: #{content || ""}")}
  end

  defp handle_mode(:static, _messages, config) do
    response = Provider.get_provider_opt(config, :echo_response, "Static response")
    {:ok, Message.assistant(response)}
  end

  defp handle_mode(:tool_call, _messages, config) do
    raw_calls = Provider.get_provider_opt(config, :echo_tool_calls, [])

    tool_calls =
      Enum.map(raw_calls, fn call ->
        ToolCall.new(%{
          id: Map.get(call, :id, "echo_call_#{System.unique_integer([:positive])}"),
          name: Map.fetch!(call, :name),
          arguments: Map.get(call, :arguments, %{})
        })
      end)

    {:ok, Message.assistant(nil, tool_calls)}
  end

  defp handle_mode(:sequence, messages, config) do
    responses = Provider.get_provider_opt(config, :echo_responses, ["Default sequence response"])
    index = messages |> Enum.count(&(&1.role == :assistant)) |> rem(length(responses))
    response = Enum.at(responses, index)

    case response do
      text when is_binary(text) -> {:ok, Message.assistant(text)}
      %{} = map -> {:ok, Message.assistant(Map.get(map, :content))}
    end
  end

  defp handle_mode(:error, _messages, config) do
    type = Provider.get_provider_opt(config, :echo_error_type, :provider_error)
    message = Provider.get_provider_opt(config, :echo_error_message, "Echo error")
    Error.wrap(type, message)
  end

  defp handle_mode(:function, messages, config) do
    fun = Provider.get_provider_opt(config, :echo_function, nil)

    if is_function(fun, 2) do
      fun.(messages, config)
    else
      Error.wrap(
        :config_error,
        "Echo function mode requires a 2-arity function in :echo_function"
      )
    end
  end

  defp handle_mode(unknown, _messages, _config) do
    Error.wrap(:config_error, "Unknown echo mode: #{inspect(unknown)}")
  end

  # --- Streaming mode handlers ---

  defp handle_stream_mode(:echo, messages, _config, caller, ref) do
    content =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: :user, content: content} when is_binary(content) -> content
        _ -> nil
      end)

    full_text = "Echo: #{content || ""}"

    full_text
    |> String.graphemes()
    |> Enum.each(fn char ->
      send(caller, {Agora.Stream, ref, StreamEvent.text_delta(char)})
    end)

    message = Message.assistant(full_text)
    send(caller, {Agora.Stream, ref, StreamEvent.message_complete(message)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
  end

  defp handle_stream_mode(:static, _messages, config, caller, ref) do
    response = Provider.get_provider_opt(config, :echo_response, "Static response")

    response
    |> String.split(~r/\s+/)
    |> Enum.intersperse(" ")
    |> Enum.each(fn word ->
      send(caller, {Agora.Stream, ref, StreamEvent.text_delta(word)})
    end)

    message = Message.assistant(response)
    send(caller, {Agora.Stream, ref, StreamEvent.message_complete(message)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
  end

  defp handle_stream_mode(:stream, _messages, config, caller, ref) do
    delay = Provider.get_provider_opt(config, :echo_stream_delay, 0)

    cond do
      events = Provider.get_provider_opt(config, :echo_stream_events, nil) ->
        Enum.each(events, fn event ->
          if delay > 0, do: Process.sleep(delay)
          send(caller, {Agora.Stream, ref, event})
        end)

      fun = Provider.get_provider_opt(config, :echo_stream_function, nil) ->
        fun.(caller, ref)

      true ->
        send(caller, {Agora.Stream, ref, StreamEvent.text_delta("stream default")})
        message = Message.assistant("stream default")
        send(caller, {Agora.Stream, ref, StreamEvent.message_complete(message)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})
    end
  end

  defp handle_stream_mode(:function, messages, config, caller, ref) do
    fun = Provider.get_provider_opt(config, :echo_function, nil)

    if is_function(fun, 4) do
      fun.(messages, config, caller, ref)
    else
      # Fall back to chat/2 result wrapped as stream events
      case chat(messages, %{
             config
             | provider_opts: Keyword.put(config.provider_opts, :echo_mode, :function)
           }) do
        {:ok, %Message{} = msg} ->
          if msg.content do
            send(caller, {Agora.Stream, ref, StreamEvent.text_delta(msg.content)})
          end

          send(caller, {Agora.Stream, ref, StreamEvent.message_complete(msg)})
          send(caller, {Agora.Stream, ref, StreamEvent.done()})

        {:error, %Error{} = error} ->
          send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
          send(caller, {Agora.Stream, ref, StreamEvent.done()})
      end
    end
  end

  defp handle_stream_mode(:tool_call, _messages, config, caller, ref) do
    # Stream tool call events
    raw_calls = Provider.get_provider_opt(config, :echo_tool_calls, [])

    tool_calls =
      Enum.with_index(raw_calls)
      |> Enum.map(fn {call, index} ->
        id = Map.get(call, :id, "echo_call_#{System.unique_integer([:positive])}")
        name = Map.fetch!(call, :name)
        arguments = Map.get(call, :arguments, %{})
        args_json = Jason.encode!(arguments)

        send(caller, {Agora.Stream, ref, StreamEvent.tool_call_start(id, name, index)})
        send(caller, {Agora.Stream, ref, StreamEvent.tool_call_delta(id, args_json)})

        ToolCall.new(%{id: id, name: name, arguments: arguments})
      end)

    message = Message.assistant(nil, tool_calls)
    send(caller, {Agora.Stream, ref, StreamEvent.message_complete(message)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
  end

  defp handle_stream_mode(:error, _messages, config, caller, ref) do
    type = Provider.get_provider_opt(config, :echo_error_type, :provider_error)
    message = Provider.get_provider_opt(config, :echo_error_message, "Echo error")
    error = Error.new(type, message)
    send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
  end

  defp handle_stream_mode(_unknown, _messages, _config, caller, ref) do
    error = Error.new(:config_error, "Unknown echo stream mode")
    send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
  end
end
