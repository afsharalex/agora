defmodule Agora.Provider.Anthropic do
  @moduledoc """
  Provider implementation for the Anthropic Messages API.

  Translates Agora messages to the Anthropic format and handles the response.
  Supports system message extraction, tool use, and adjacent role merging.
  """

  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Config, Error, Message, StreamEvent, ToolCall}
  alias Agora.Provider.{SSE, StreamAccumulator}

  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @default_timeout 60_000

  @impl true
  def chat(messages, %AgentConfig{} = config) do
    with {:ok, api_key} <- fetch_api_key(config),
         body <- build_request_body(messages, config),
         {:ok, response} <- do_request(body, api_key, config) do
      parse_response(response)
    end
  end

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
        case Config.api_key(:anthropic) do
          nil -> Error.wrap(:auth_error, "Missing API key for Anthropic provider")
          key -> {:ok, key}
        end
    end
  end

  defp get_opt(%AgentConfig{} = config, key, default) do
    case Keyword.fetch(config.provider_opts, key) do
      {:ok, value} -> value
      :error -> Config.get(:"anthropic_#{key}", default)
    end
  end

  defp build_request_body(messages, config) do
    {system_text, chat_messages} = extract_system(messages, config)
    anthropic_messages = translate_messages(chat_messages)
    max_tokens = get_opt(config, :max_tokens, 4096)

    body =
      %{
        "model" => config.model,
        "messages" => anthropic_messages,
        "max_tokens" => max_tokens
      }

    body = if system_text != "", do: Map.put(body, "system", system_text), else: body
    maybe_add_tools(body, AgentConfig.tool_definitions(config))
  end

  defp extract_system(messages, config) do
    system_parts =
      messages
      |> Enum.filter(&(&1.role == :system))
      |> Enum.map(& &1.content)

    instructions = if config.instructions != "", do: [config.instructions], else: []

    system_text =
      (instructions ++ system_parts)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    non_system = Enum.reject(messages, &(&1.role == :system))
    {system_text, non_system}
  end

  defp translate_messages(messages) do
    messages
    |> Enum.flat_map(&translate_message/1)
    |> merge_adjacent_roles()
  end

  defp translate_message(%Message{role: :user, content: content}) do
    [%{"role" => "user", "content" => content}]
  end

  defp translate_message(%Message{role: :assistant} = msg) do
    content_blocks = build_assistant_content_blocks(msg)
    [%{"role" => "assistant", "content" => content_blocks}]
  end

  defp translate_message(%Message{role: :tool} = msg) do
    tool_blocks =
      Enum.map(msg.tool_results, fn result ->
        block = %{
          "type" => "tool_result",
          "tool_use_id" => result.tool_call_id,
          "content" => result.content
        }

        if result.is_error, do: Map.put(block, "is_error", true), else: block
      end)

    text_blocks =
      if msg.content && msg.content != "" do
        [%{"type" => "text", "text" => msg.content}]
      else
        []
      end

    # tool_result blocks first, then text
    [%{"role" => "user", "content" => tool_blocks ++ text_blocks}]
  end

  defp build_assistant_content_blocks(%Message{content: content, tool_calls: tool_calls}) do
    text_blocks =
      if content && content != "" do
        [%{"type" => "text", "text" => content}]
      else
        []
      end

    tool_blocks =
      Enum.map(tool_calls, fn tc ->
        %{
          "type" => "tool_use",
          "id" => tc.id,
          "name" => tc.name,
          "input" => tc.arguments
        }
      end)

    text_blocks ++ tool_blocks
  end

  defp merge_adjacent_roles(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        case acc do
          nil ->
            {:cont, msg}

          prev ->
            if prev["role"] == msg["role"] do
              {:cont, merge_two_messages(prev, msg)}
            else
              {:cont, prev, msg}
            end
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp merge_two_messages(a, b) do
    content_a = normalize_content(a["content"])
    content_b = normalize_content(b["content"])
    %{a | "content" => content_a ++ content_b}
  end

  defp normalize_content(content) when is_list(content), do: content

  defp normalize_content(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    tool_defs =
      Enum.map(tools, fn tool ->
        %{
          "name" => to_string(tool["name"] || tool[:name]),
          "description" => tool["description"] || tool[:description] || "",
          "input_schema" =>
            tool["parameters"] || tool[:parameters] || tool["input_schema"] ||
              tool[:input_schema] || %{}
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
        url: "#{base_url}/v1/messages",
        json: body,
        headers:
          [
            {"x-api-key", api_key},
            {"anthropic-version", @api_version},
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
        Error.wrap(:timeout, "Anthropic API request timed out")

      {:error, %Req.TransportError{reason: reason}} ->
        Error.wrap(:provider_error, "Anthropic transport error: #{inspect(reason)}")

      {:error, exception} ->
        Error.wrap(:provider_error, "Anthropic request failed: #{inspect(exception)}")
    end
  end

  defp map_http_error(401, _body) do
    Error.wrap(:auth_error, "Anthropic API authentication failed (401)")
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
    content_blocks = Map.get(body, "content", [])

    text =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    tool_calls =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        ToolCall.new(%{
          id: block["id"],
          name: block["name"],
          arguments: block["input"] || %{}
        })
      end)

    content = if text == "", do: nil, else: text

    metadata =
      %{}
      |> maybe_put(:usage, body["usage"])
      |> maybe_put(:stop_reason, body["stop_reason"])
      |> maybe_put(:model, body["model"])

    {:ok, Message.new(:assistant, content, tool_calls: tool_calls, metadata: metadata)}
  end

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
      provider: :anthropic,
      model: config.model,
      message_count: length(body["messages"] || [])
    }

    req_opts =
      [
        url: "#{base_url}/v1/messages",
        json: body,
        headers:
          [
            {"x-api-key", api_key},
            {"anthropic-version", @api_version},
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
        error = Error.new(:timeout, "Anthropic streaming request timed out")
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
        error = Error.new(:provider_error, "Anthropic streaming failed: #{inspect(exception)}")
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
    # Req.Test plug adapter returns full body as binary
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
    # Handle unexpected body format
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
        error = Error.new(:timeout, "Anthropic stream receive timed out after 300s")
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
        handle_anthropic_event(parsed, acc, caller, ref)

      {:error, _} ->
        acc
    end
  end

  defp handle_anthropic_event(%{"type" => "message_start"} = event, acc, _caller, _ref) do
    metadata = event["message"] || %{}

    %{
      acc
      | metadata: Map.merge(acc.metadata, %{model: metadata["model"], usage: metadata["usage"]})
    }
  end

  defp handle_anthropic_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         acc,
         caller,
         ref
       ) do
    case block["type"] do
      "tool_use" ->
        id = block["id"]
        name = block["name"]
        send(caller, {Agora.Stream, ref, StreamEvent.tool_call_start(id, name, index)})
        StreamAccumulator.apply(acc, StreamEvent.tool_call_start(id, name, index))

      _ ->
        acc
    end
  end

  defp handle_anthropic_event(
         %{"type" => "content_block_delta", "index" => index, "delta" => delta},
         acc,
         caller,
         ref
       ) do
    case delta["type"] do
      "text_delta" ->
        text = delta["text"] || ""
        event = StreamEvent.text_delta(text)
        send(caller, {Agora.Stream, ref, event})
        StreamAccumulator.apply(acc, event)

      "input_json_delta" ->
        json_fragment = delta["partial_json"] || ""
        # Use the event index to look up the correct tool call
        tool_id =
          case Map.get(acc.tool_calls, index) do
            %{id: id} -> id
            nil -> "unknown"
          end

        event = StreamEvent.tool_call_delta(tool_id, json_fragment)
        send(caller, {Agora.Stream, ref, event})
        StreamAccumulator.apply(acc, event)

      _ ->
        acc
    end
  end

  # Fallback for content_block_delta without index (shouldn't happen per spec, but defensive)
  defp handle_anthropic_event(
         %{"type" => "content_block_delta", "delta" => delta},
         acc,
         caller,
         ref
       ) do
    handle_anthropic_event(
      %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
      acc,
      caller,
      ref
    )
  end

  defp handle_anthropic_event(%{"type" => "content_block_stop"}, acc, _caller, _ref), do: acc

  defp handle_anthropic_event(
         %{"type" => "message_delta", "delta" => delta, "usage" => usage},
         acc,
         _caller,
         _ref
       ) do
    %{acc | metadata: Map.merge(acc.metadata, %{stop_reason: delta["stop_reason"], usage: usage})}
  end

  defp handle_anthropic_event(%{"type" => "message_delta", "delta" => delta}, acc, _caller, _ref) do
    %{acc | metadata: Map.merge(acc.metadata, %{stop_reason: delta["stop_reason"]})}
  end

  defp handle_anthropic_event(%{"type" => "message_stop"}, acc, _caller, _ref), do: acc

  defp handle_anthropic_event(%{"type" => "error", "error" => error_data}, acc, caller, ref) do
    error = Error.new(:provider_error, error_data["message"] || "Anthropic stream error")
    send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
    acc
  end

  defp handle_anthropic_event(_unknown, acc, _caller, _ref), do: acc

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
