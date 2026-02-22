defmodule Agora.Provider.Gemini do
  @moduledoc """
  Provider implementation for the Google Gemini API.

  Translates Agora messages to the Gemini format and handles the response.
  Supports system instruction extraction, tool use with positional correlation,
  and adjacent role merging.

  ## API Key Resolution

  The API key is resolved in this order:

  1. `provider_opts[:api_key]` (per-agent override)
  2. Application config `:gemini_api_key` (set by `GEMINI_API_KEY`)
  3. Application config `:google_api_key` (set by `GOOGLE_API_KEY`)

  The API key is sent as a query parameter (`?key=API_KEY`), not as a header.

  ## Tool Call Correlation

  Gemini does not provide tool call IDs. Synthetic IDs `"gemini_tc_{index}"`
  are generated based on part position. Tool results must be returned in the
  same order as the original tool calls for correct positional correlation.
  """

  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Config, Error, Message, StreamEvent, ToolCall}
  alias Agora.Provider.{SSE, StreamAccumulator}

  @default_base_url "https://generativelanguage.googleapis.com"
  @default_timeout 60_000

  @doc "Sends messages to the Gemini API and returns the assistant response."
  @spec chat([Message.t()], AgentConfig.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  @impl true
  def chat(messages, %AgentConfig{} = config) do
    with {:ok, api_key} <- fetch_api_key(config),
         body <- build_request_body(messages, config),
         {:ok, response} <- do_request(body, api_key, config) do
      parse_response(response)
    end
  end

  @doc "Starts a streaming request to the Gemini API."
  @spec stream_chat([Message.t()], AgentConfig.t()) ::
          {:ok, %{pid: pid(), ref: reference()}} | {:error, Error.t()}
  @impl true
  def stream_chat(messages, %AgentConfig{} = config) do
    caller = self()
    ref = make_ref()

    with {:ok, api_key} <- fetch_api_key(config) do
      body = build_request_body(messages, config)

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
        case Config.api_key(:gemini) do
          nil ->
            case Config.api_key(:google) do
              nil -> Error.wrap(:auth_error, "Missing API key for Gemini provider")
              key -> {:ok, key}
            end

          key ->
            {:ok, key}
        end
    end
  end

  defp get_opt(%AgentConfig{} = config, key, default) do
    case Keyword.fetch(config.provider_opts, key) do
      {:ok, value} -> value
      :error -> Config.get(:"gemini_#{key}", default)
    end
  end

  defp build_request_body(messages, config) do
    {system_text, chat_messages} = extract_system(messages, config)
    contents = translate_messages(chat_messages)

    body = %{"contents" => contents}

    body =
      if system_text != "" do
        Map.put(body, "systemInstruction", %{
          "role" => "user",
          "parts" => [%{"text" => system_text}]
        })
      else
        body
      end

    body = maybe_add_generation_config(body, config)
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
    [%{"role" => "user", "parts" => [%{"text" => content}]}]
  end

  defp translate_message(%Message{role: :assistant} = msg) do
    parts = build_assistant_parts(msg)
    [%{"role" => "model", "parts" => parts}]
  end

  defp translate_message(%Message{role: :tool} = msg) do
    parts =
      Enum.map(msg.tool_results, fn result ->
        response =
          if result.is_error do
            %{"error" => result.content}
          else
            %{"result" => result.content}
          end

        %{"functionResponse" => %{"name" => result.name, "response" => response}}
      end)

    [%{"role" => "user", "parts" => parts}]
  end

  defp build_assistant_parts(%Message{content: content, tool_calls: tool_calls}) do
    text_parts =
      if content && content != "" do
        [%{"text" => content}]
      else
        []
      end

    tool_parts =
      Enum.map(tool_calls, fn tc ->
        %{"functionCall" => %{"name" => tc.name, "args" => tc.arguments}}
      end)

    text_parts ++ tool_parts
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
    %{a | "parts" => a["parts"] ++ b["parts"]}
  end

  defp maybe_add_generation_config(body, config) do
    gen_config = %{}

    gen_config =
      case Keyword.fetch(config.provider_opts, :temperature) do
        {:ok, temp} -> Map.put(gen_config, "temperature", temp)
        :error -> gen_config
      end

    gen_config =
      case Keyword.fetch(config.provider_opts, :max_tokens) do
        {:ok, max} -> Map.put(gen_config, "maxOutputTokens", max)
        :error -> gen_config
      end

    if gen_config == %{}, do: body, else: Map.put(body, "generationConfig", gen_config)
  end

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    function_declarations =
      Enum.map(tools, fn tool ->
        decl = %{
          "name" => to_string(tool["name"] || tool[:name]),
          "description" => tool["description"] || tool[:description] || ""
        }

        params =
          tool["parameters"] || tool[:parameters] || tool["input_schema"] ||
            tool[:input_schema]

        if params, do: Map.put(decl, "parameters", params), else: decl
      end)

    Map.put(body, "tools", [%{"functionDeclarations" => function_declarations}])
  end

  defp do_request(body, api_key, config) do
    base_url = get_opt(config, :base_url, @default_base_url)
    timeout = get_opt(config, :timeout, @default_timeout)
    req_options = get_opt(config, :req_options, [])
    {extra_headers, req_options} = Keyword.pop(req_options, :headers, [])
    url = "#{base_url}/v1beta/models/#{config.model}:generateContent?key=#{api_key}"

    req_opts =
      [
        url: url,
        json: body,
        headers: [{"content-type", "application/json"}] ++ extra_headers,
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
        Error.wrap(:timeout, "Gemini API request timed out")

      {:error, %Req.TransportError{reason: reason}} ->
        Error.wrap(:provider_error, "Gemini transport error: #{inspect(reason)}")

      {:error, exception} ->
        Error.wrap(:provider_error, "Gemini request failed: #{inspect(exception)}")
    end
  end

  defp map_http_error(status, _body) when status in [401, 403] do
    Error.wrap(:auth_error, "Gemini API authentication failed (#{status})")
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
    candidate = get_in(body, ["candidates", Access.at(0)]) || %{}
    parts = get_in(candidate, ["content", "parts"]) || []

    text =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    tool_calls =
      parts
      |> Enum.with_index()
      |> Enum.flat_map(fn {part, index} ->
        case part do
          %{"functionCall" => %{"name" => name, "args" => args}} ->
            [
              ToolCall.new(%{
                id: "gemini_tc_#{index}",
                name: name,
                arguments: args || %{}
              })
            ]

          _ ->
            []
        end
      end)

    content = if text == "", do: nil, else: text

    metadata =
      %{}
      |> maybe_put_usage(body["usageMetadata"])
      |> maybe_put(:stop_reason, candidate["finishReason"])
      |> maybe_put(:model, body["modelVersion"])

    {:ok, Message.new(:assistant, content, tool_calls: tool_calls, metadata: metadata)}
  end

  defp maybe_put_usage(map, nil), do: map

  defp maybe_put_usage(map, usage) do
    normalized = %{
      prompt_tokens: usage["promptTokenCount"],
      completion_tokens: usage["candidatesTokenCount"],
      total_tokens: usage["totalTokenCount"]
    }

    Map.put(map, :usage, normalized)
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
    url = "#{base_url}/v1beta/models/#{config.model}:streamGenerateContent?alt=sse&key=#{api_key}"

    meta = %{
      provider: :gemini,
      model: config.model,
      message_count: length(body["contents"] || [])
    }

    req_opts =
      [
        url: url,
        json: body,
        headers: [{"content-type", "application/json"}] ++ extra_headers,
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
        error = Error.new(:timeout, "Gemini streaming request timed out")
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
        error = Error.new(:provider_error, "Gemini streaming failed: #{inspect(exception)}")
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
        error = Error.new(:timeout, "Gemini stream receive timed out after 300s")
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

  defp translate_sse_event(%{data: data}, acc, caller, ref) do
    case Jason.decode(data) do
      {:ok, parsed} ->
        handle_gemini_event(parsed, acc, caller, ref)

      {:error, _} ->
        acc
    end
  end

  defp handle_gemini_event(%{"candidates" => [candidate | _]} = event, acc, caller, ref) do
    parts = get_in(candidate, ["content", "parts"]) || []
    tc_offset = map_size(acc.tool_calls)

    acc =
      Enum.with_index(parts)
      |> Enum.reduce(acc, fn {part, local_index}, acc ->
        cond do
          Map.has_key?(part, "text") ->
            text = part["text"]
            stream_event = StreamEvent.text_delta(text)
            send(caller, {Agora.Stream, ref, stream_event})
            StreamAccumulator.apply(acc, stream_event)

          Map.has_key?(part, "functionCall") ->
            fc = part["functionCall"]
            global_index = tc_offset + local_index
            id = "gemini_tc_#{global_index}"
            name = fc["name"]
            args = fc["args"] || %{}

            start_event = StreamEvent.tool_call_start(id, name, global_index)
            send(caller, {Agora.Stream, ref, start_event})
            acc = StreamAccumulator.apply(acc, start_event)

            args_json = Jason.encode!(args)
            delta_event = StreamEvent.tool_call_delta(id, args_json)
            send(caller, {Agora.Stream, ref, delta_event})
            StreamAccumulator.apply(acc, delta_event)

          true ->
            acc
        end
      end)

    # Capture metadata from streaming event
    acc = maybe_update_stream_metadata(acc, event, candidate)
    acc
  end

  defp handle_gemini_event(_other, acc, _caller, _ref), do: acc

  defp maybe_update_stream_metadata(acc, event, candidate) do
    metadata = acc.metadata

    metadata =
      case event["usageMetadata"] do
        nil ->
          metadata

        usage ->
          Map.put(metadata, :usage, %{
            prompt_tokens: usage["promptTokenCount"],
            completion_tokens: usage["candidatesTokenCount"],
            total_tokens: usage["totalTokenCount"]
          })
      end

    metadata =
      case candidate["finishReason"] do
        nil -> metadata
        reason -> Map.put(metadata, :stop_reason, reason)
      end

    metadata =
      case event["modelVersion"] do
        nil -> metadata
        model -> Map.put(metadata, :model, model)
      end

    %{acc | metadata: metadata}
  end

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
