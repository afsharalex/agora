defmodule Agora.Provider.OpenAI do
  @moduledoc """
  Provider implementation for the OpenAI Chat Completions API.

  Translates Agora messages to the OpenAI format and handles the response.
  Supports inline system messages, JSON string tool arguments, and
  tool result expansion.
  """

  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Config, Error, Message, StreamEvent, ToolCall}
  alias Agora.Provider.{SSE, StreamAccumulator}

  @default_base_url "https://api.openai.com"
  @default_timeout 60_000

  @doc "Sends messages to the OpenAI Chat Completions API and returns the assistant response."
  @spec chat([Message.t()], AgentConfig.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  @impl true
  def chat(messages, %AgentConfig{} = config) do
    with {:ok, api_key} <- fetch_api_key(config),
         body <- build_request_body(messages, config),
         {:ok, response} <- do_request(body, api_key, config) do
      parse_response(response)
    end
  end

  @doc "Starts a streaming request to the OpenAI Chat Completions API."
  @spec stream_chat([Message.t()], AgentConfig.t()) ::
          {:ok, %{pid: pid(), ref: reference()}} | {:error, Error.t()}
  @impl true
  def stream_chat(messages, %AgentConfig{} = config) do
    caller = self()
    ref = make_ref()

    with {:ok, api_key} <- fetch_api_key(config) do
      body = build_request_body(messages, config) |> Map.put("stream", true)

      {:ok, pid} =
        Task.Supervisor.start_child(Agora.StreamSupervisor, fn ->
          do_stream_request(body, api_key, config, caller, ref)
        end)

      {:ok, %{pid: pid, ref: ref}}
    end
  end

  defp fetch_api_key(config) do
    case Keyword.fetch(config.provider_opts, :api_key) do
      {:ok, key} when not is_nil(key) ->
        {:ok, key}

      _ ->
        case Config.api_key(:openai) do
          nil -> Error.wrap(:auth_error, "Missing API key for OpenAI provider")
          key -> {:ok, key}
        end
    end
  end

  defp get_opt(%AgentConfig{} = config, key, default) do
    case Keyword.fetch(config.provider_opts, key) do
      {:ok, value} -> value
      :error -> Config.get(:"openai_#{key}", default)
    end
  end

  defp build_request_body(messages, config) do
    openai_messages = translate_messages(messages, config)

    body = %{
      "model" => config.model,
      "messages" => openai_messages
    }

    maybe_add_tools(body, AgentConfig.tool_definitions(config))
  end

  defp translate_messages(messages, config) do
    instructions_msg =
      if config.instructions != "" do
        [%{"role" => "system", "content" => config.instructions}]
      else
        []
      end

    translated = Enum.flat_map(messages, &translate_message/1)
    instructions_msg ++ translated
  end

  defp translate_message(%Message{role: :system, content: content}) do
    [%{"role" => "system", "content" => content}]
  end

  defp translate_message(%Message{role: :user, content: content}) do
    [%{"role" => "user", "content" => content}]
  end

  defp translate_message(%Message{role: :assistant} = msg) do
    base = %{"role" => "assistant"}

    base =
      if msg.content && msg.content != "" do
        Map.put(base, "content", msg.content)
      else
        Map.put(base, "content", nil)
      end

    result =
      if msg.tool_calls != [] do
        tool_calls =
          Enum.map(msg.tool_calls, fn tc ->
            %{
              "id" => tc.id,
              "type" => "function",
              "function" => %{
                "name" => tc.name,
                "arguments" => encode_arguments(tc.arguments)
              }
            }
          end)

        Map.put(base, "tool_calls", tool_calls)
      else
        base
      end

    [result]
  end

  defp translate_message(%Message{role: :tool} = msg) do
    # One Agora :tool message with N results → N separate OpenAI tool messages
    Enum.map(msg.tool_results, fn result ->
      %{
        "role" => "tool",
        "tool_call_id" => result.tool_call_id,
        "content" => result.content
      }
    end)
  end

  defp encode_arguments(args) when is_map(args), do: Jason.encode!(args)
  defp encode_arguments(args) when is_binary(args), do: args

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    tool_defs =
      Enum.map(tools, fn tool ->
        %{
          "type" => "function",
          "function" => %{
            "name" => to_string(tool["name"] || tool[:name]),
            "description" => tool["description"] || tool[:description] || "",
            "parameters" =>
              tool["parameters"] || tool[:parameters] || tool["input_schema"] ||
                tool[:input_schema] || %{}
          }
        }
      end)

    Map.put(body, "tools", tool_defs)
  end

  defp do_request(body, api_key, config) do
    base_url = get_opt(config, :base_url, @default_base_url)
    timeout = get_opt(config, :timeout, @default_timeout)
    req_options = get_opt(config, :req_options, [])
    {extra_headers, req_options} = Keyword.pop(req_options, :headers, [])

    req_opts =
      [
        url: "#{base_url}/v1/chat/completions",
        json: body,
        headers:
          [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ] ++ extra_headers,
        receive_timeout: timeout,
        retry: false
      ]
      |> Keyword.merge(req_options)

    case Req.post(Req.new(req_opts)) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        map_http_error(status, resp_body)

      {:error, %Req.TransportError{reason: :timeout}} ->
        Error.wrap(:timeout, "OpenAI API request timed out")

      {:error, %Req.TransportError{reason: reason}} ->
        Error.wrap(:provider_error, "OpenAI transport error: #{inspect(reason)}")

      {:error, exception} ->
        Error.wrap(:provider_error, "OpenAI request failed: #{inspect(exception)}")
    end
  end

  defp map_http_error(401, _body) do
    Error.wrap(:auth_error, "OpenAI API authentication failed (401)")
  end

  defp map_http_error(429, body) do
    message = get_in(body, ["error", "message"]) || "Rate limit exceeded"
    Error.wrap(:rate_limit, message)
  end

  defp map_http_error(400, body) do
    message = get_in(body, ["error", "message"]) || "Bad request"
    Error.wrap(:validation_error, message, %{status: 400, body: body})
  end

  defp map_http_error(status, body) when status >= 500 do
    message = get_in(body, ["error", "message"]) || "Server error (#{status})"
    Error.wrap(:provider_error, message, %{status: status, body: body})
  end

  defp map_http_error(status, body) do
    message = get_in(body, ["error", "message"]) || "HTTP error #{status}"
    Error.wrap(:provider_error, message, %{status: status, body: body})
  end

  defp parse_response(body) do
    choice = get_in(body, ["choices", Access.at(0), "message"]) || %{}

    content = choice["content"]
    content = if content == "", do: nil, else: content

    tool_calls = parse_tool_calls(choice["tool_calls"])

    metadata =
      %{}
      |> maybe_put(:usage, body["usage"])
      |> maybe_put(:stop_reason, get_in(body, ["choices", Access.at(0), "finish_reason"]))
      |> maybe_put(:model, body["model"])

    {:ok, Message.new(:assistant, content, tool_calls: tool_calls, metadata: metadata)}
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      func = tc["function"] || %{}
      arguments = decode_arguments(func["arguments"])

      ToolCall.new(%{
        id: tc["id"],
        name: func["name"],
        arguments: arguments
      })
    end)
  end

  defp decode_arguments(nil), do: %{}
  defp decode_arguments(""), do: %{}

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"_raw" => args}
    end
  end

  defp decode_arguments(args) when is_map(args), do: args

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- Streaming ---

  defp do_stream_request(body, api_key, config, caller, ref) do
    base_url = get_opt(config, :base_url, @default_base_url)
    timeout = get_opt(config, :timeout, @default_timeout)
    req_options = get_opt(config, :req_options, [])
    {extra_headers, req_options} = Keyword.pop(req_options, :headers, [])
    start_time = System.monotonic_time()

    meta = %{
      provider: :openai,
      model: config.model,
      message_count: length(body["messages"] || [])
    }

    req_opts =
      [
        url: "#{base_url}/v1/chat/completions",
        json: body,
        headers:
          [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ] ++ extra_headers,
        receive_timeout: timeout,
        retry: false,
        into: :self
      ]
      |> Keyword.merge(req_options)

    result =
      case Req.post(Req.new(req_opts)) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          process_stream_body(resp_body, caller, ref)

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          {:error, status, normalize_error_body(resp_body)}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, :timeout, nil}

        {:error, exception} ->
          {:error, :transport, exception}
      end

    case result do
      :ok ->
        Agora.Telemetry.emit(
          [:agora, :provider, :stream, :stop],
          %{duration: System.monotonic_time() - start_time},
          meta
        )

      {:error, :timeout, _} ->
        error = Error.new(:timeout, "OpenAI streaming request timed out")
        send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})

        Agora.Telemetry.emit(
          [:agora, :provider, :stream, :stop],
          %{duration: System.monotonic_time() - start_time},
          Map.put(meta, :error, error)
        )

      {:error, status, resp_body} when is_integer(status) ->
        {:error, error} = map_http_error(status, resp_body)
        send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})

        Agora.Telemetry.emit(
          [:agora, :provider, :stream, :stop],
          %{duration: System.monotonic_time() - start_time},
          Map.put(meta, :error, error)
        )

      {:error, :transport, exception} ->
        error = Error.new(:provider_error, "OpenAI streaming failed: #{inspect(exception)}")
        send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})

        Agora.Telemetry.emit(
          [:agora, :provider, :stream, :stop],
          %{duration: System.monotonic_time() - start_time},
          Map.put(meta, :error, error)
        )
    end
  end

  defp process_stream_body(%Req.Response.Async{} = async, caller, ref) do
    sse_state = SSE.new()
    acc = StreamAccumulator.new()
    stream_receive_loop(async, sse_state, acc, caller, ref)
  end

  defp process_stream_body(body, caller, ref) when is_binary(body) do
    sse_state = SSE.new()
    {events, sse_state} = SSE.parse(sse_state, body)
    {remaining, _sse_state} = SSE.flush(sse_state)
    all_events = events ++ remaining

    acc = StreamAccumulator.new()
    acc = process_sse_events(all_events, acc, caller, ref)
    finalize_stream(acc, caller, ref)
    :ok
  end

  defp process_stream_body(_other, caller, ref) do
    error = Error.new(:streaming_error, "Unexpected response body format")
    send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
    :ok
  end

  defp stream_receive_loop(
         %Req.Response.Async{ref: async_ref} = async,
         sse_state,
         acc,
         caller,
         ref
       ) do
    receive do
      {^async_ref, {:data, chunk}} ->
        {events, sse_state} = SSE.parse(sse_state, chunk)
        acc = process_sse_events(events, acc, caller, ref)
        stream_receive_loop(async, sse_state, acc, caller, ref)

      {^async_ref, :done} ->
        {remaining, _sse_state} = SSE.flush(sse_state)
        acc = process_sse_events(remaining, acc, caller, ref)
        finalize_stream(acc, caller, ref)
        :ok

      {^async_ref, {:error, reason}} ->
        error = Error.new(:streaming_error, "Stream error: #{inspect(reason)}")
        send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})
        :ok
    after
      300_000 ->
        error = Error.new(:timeout, "OpenAI stream receive timed out after 300s")
        send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})
        :ok
    end
  end

  defp process_sse_events(events, acc, caller, ref) do
    Enum.reduce(events, acc, fn sse_event, acc ->
      translate_sse_event(sse_event, acc, caller, ref)
    end)
  end

  defp translate_sse_event(%{data: "[DONE]"}, acc, _caller, _ref), do: acc

  defp translate_sse_event(%{data: data}, acc, caller, ref) do
    case Jason.decode(data) do
      {:ok, parsed} ->
        handle_openai_event(parsed, acc, caller, ref)

      {:error, _} ->
        acc
    end
  end

  defp handle_openai_event(%{"choices" => [%{"delta" => delta} = choice | _]}, acc, caller, ref) do
    acc = handle_delta_content(delta, acc, caller, ref)
    acc = handle_delta_tool_calls(delta, acc, caller, ref)

    case choice["finish_reason"] do
      nil -> acc
      _reason -> acc
    end
  end

  defp handle_openai_event(_other, acc, _caller, _ref), do: acc

  defp handle_delta_content(%{"content" => content}, acc, caller, ref)
       when is_binary(content) and content != "" do
    event = StreamEvent.text_delta(content)
    send(caller, {Agora.Stream, ref, event})
    StreamAccumulator.apply(acc, event)
  end

  defp handle_delta_content(_delta, acc, _caller, _ref), do: acc

  defp handle_delta_tool_calls(%{"tool_calls" => tool_calls}, acc, caller, ref)
       when is_list(tool_calls) do
    Enum.reduce(tool_calls, acc, fn tc, acc ->
      index = tc["index"] || 0
      func = tc["function"] || %{}

      cond do
        # First chunk for a tool call (has id and name)
        tc["id"] && func["name"] ->
          event = StreamEvent.tool_call_start(tc["id"], func["name"], index)
          send(caller, {Agora.Stream, ref, event})
          acc = StreamAccumulator.apply(acc, event)

          # May also have arguments in the first chunk
          if func["arguments"] && func["arguments"] != "" do
            # Look up tool call id from accumulator
            tool_id = tc["id"]
            delta_event = StreamEvent.tool_call_delta(tool_id, func["arguments"])
            send(caller, {Agora.Stream, ref, delta_event})
            StreamAccumulator.apply(acc, delta_event)
          else
            acc
          end

        # Subsequent delta chunks (arguments only, may lack id/name)
        func["arguments"] && func["arguments"] != "" ->
          # Get tool call id from accumulator by index
          tool_id =
            case Map.get(acc.tool_calls, index) do
              %{id: id} -> id
              nil -> tc["id"] || "unknown"
            end

          event = StreamEvent.tool_call_delta(tool_id, func["arguments"])
          send(caller, {Agora.Stream, ref, event})
          StreamAccumulator.apply(acc, event)

        true ->
          acc
      end
    end)
  end

  defp handle_delta_tool_calls(_delta, acc, _caller, _ref), do: acc

  defp finalize_stream(acc, caller, ref) do
    message = StreamAccumulator.to_message(acc)
    send(caller, {Agora.Stream, ref, StreamEvent.message_complete(message)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
  end

  defp normalize_error_body(%Req.Response.Async{}), do: %{}

  defp normalize_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_error_body(body) when is_map(body), do: body
  defp normalize_error_body(_), do: %{}
end
