defmodule Agora.Provider.Ollama do
  @moduledoc """
  Provider implementation for the Ollama API.

  Translates Agora messages to the Ollama native chat format and handles
  the response. Supports system messages inline, tool use, and optional
  authentication.

  ## API Key Resolution

  Unlike other providers, Ollama does not require an API key by default.
  When no key is configured, requests are sent without authentication.

  1. `provider_opts[:api_key]` (per-agent override)
  2. Application config `:ollama_api_key` (set by `OLLAMA_API_KEY`)
  3. No key → no auth header (OK for local Ollama)

  ## Tool Call Correlation

  Ollama does not provide tool call IDs. Synthetic IDs `"ollama_tc_{index}"`
  are generated based on array position. Tool results use `tool_name` (not
  `tool_call_id`) for correlation.

  ## Metadata

  Ollama-native fields are preserved in `Message.metadata` (duration metrics
  in nanoseconds, eval counts) rather than normalizing to OpenAI conventions,
  since they include timing info not available from other providers.
  """

  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Config, Error, Message, StreamEvent, ToolCall}
  alias Agora.Provider.{NDJSON, StreamAccumulator}

  @default_base_url "http://localhost:11434"
  @default_timeout 120_000

  @doc "Sends messages to the Ollama API and returns the assistant response."
  @spec chat([Message.t()], AgentConfig.t()) :: {:ok, Message.t()} | {:error, Error.t()}
  @impl true
  def chat(messages, %AgentConfig{} = config) do
    with {:ok, api_key} <- fetch_api_key(config),
         body <- build_request_body(messages, config),
         {:ok, response} <- do_request(body, api_key, config) do
      parse_response(response)
    end
  end

  @doc "Starts a streaming request to the Ollama API."
  @spec stream_chat([Message.t()], AgentConfig.t()) ::
          {:ok, %{pid: pid(), ref: reference()}} | {:error, Error.t()}
  @impl true
  def stream_chat(messages, %AgentConfig{} = config) do
    caller = self()
    ref = make_ref()

    with {:ok, api_key} <- fetch_api_key(config) do
      body =
        build_request_body(messages, config)
        |> Map.put("stream", true)

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
        case Config.api_key(:ollama) do
          nil -> {:ok, nil}
          key -> {:ok, key}
        end
    end
  end

  defp get_opt(%AgentConfig{} = config, key, default) do
    case Keyword.fetch(config.provider_opts, key) do
      {:ok, value} -> value
      :error -> Config.get(:"ollama_#{key}", default)
    end
  end

  defp build_request_body(messages, config) do
    ollama_messages = translate_messages(messages, config)

    body = %{
      "model" => config.model,
      "messages" => ollama_messages,
      "stream" => false
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
    base = %{"role" => "assistant", "content" => msg.content || ""}

    result =
      if msg.tool_calls != [] do
        tool_calls =
          Enum.map(msg.tool_calls, fn tc ->
            %{"function" => %{"name" => tc.name, "arguments" => tc.arguments}}
          end)

        Map.put(base, "tool_calls", tool_calls)
      else
        base
      end

    [result]
  end

  defp translate_message(%Message{role: :tool} = msg) do
    Enum.map(msg.tool_results, fn result ->
      %{
        "role" => "tool",
        "tool_name" => result.name,
        "content" => result.content
      }
    end)
  end

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

    auth_headers =
      if api_key do
        [{"authorization", "Bearer #{api_key}"}]
      else
        []
      end

    req_opts =
      [
        url: "#{base_url}/api/chat",
        json: body,
        headers: auth_headers ++ [{"content-type", "application/json"}] ++ extra_headers,
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
        Error.wrap(:timeout, "Ollama API request timed out")

      {:error, %Req.TransportError{reason: reason}} ->
        Error.wrap(:provider_error, "Ollama transport error: #{inspect(reason)}")

      {:error, exception} ->
        Error.wrap(:provider_error, "Ollama request failed: #{inspect(exception)}")
    end
  end

  defp map_http_error(status, body) when status in [400, 404] do
    message = extract_error_message(body) || "Bad request (#{status})"
    Error.wrap(:validation_error, message, %{status: status, body: body})
  end

  defp map_http_error(status, body) when status >= 500 do
    message = extract_error_message(body) || "Server error (#{status})"
    Error.wrap(:provider_error, message, %{status: status, body: body})
  end

  defp map_http_error(status, body) do
    message = extract_error_message(body) || "HTTP error #{status}"
    Error.wrap(:provider_error, message, %{status: status, body: body})
  end

  defp extract_error_message(body) when is_map(body), do: body["error"]
  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_), do: nil

  defp parse_response(body) do
    message_data = body["message"] || %{}
    content = message_data["content"]
    content = if content == "", do: nil, else: content

    tool_calls = parse_tool_calls(message_data["tool_calls"])

    metadata =
      %{}
      |> maybe_put(:model, body["model"])
      |> maybe_put(:stop_reason, body["done_reason"])
      |> maybe_put(:total_duration, body["total_duration"])
      |> maybe_put(:load_duration, body["load_duration"])
      |> maybe_put(:prompt_eval_count, body["prompt_eval_count"])
      |> maybe_put(:prompt_eval_duration, body["prompt_eval_duration"])
      |> maybe_put(:eval_count, body["eval_count"])
      |> maybe_put(:eval_duration, body["eval_duration"])

    {:ok, Message.new(:assistant, content, tool_calls: tool_calls, metadata: metadata)}
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Enum.map(fn {tc, index} ->
      func = tc["function"] || %{}
      arguments = normalize_arguments(func["arguments"])

      ToolCall.new(%{
        id: "ollama_tc_#{index}",
        name: func["name"],
        arguments: arguments
      })
    end)
  end

  defp normalize_arguments(nil), do: %{}
  defp normalize_arguments(args) when is_map(args), do: args

  defp normalize_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"_raw" => args}
    end
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

    auth_headers =
      if api_key do
        [{"authorization", "Bearer #{api_key}"}]
      else
        []
      end

    meta = %{
      provider: :ollama,
      model: config.model,
      message_count: length(body["messages"] || [])
    }

    req_opts =
      [
        url: "#{base_url}/api/chat",
        json: body,
        headers: auth_headers ++ [{"content-type", "application/json"}] ++ extra_headers,
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
        error = Error.new(:timeout, "Ollama streaming request timed out")
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
        error = Error.new(:provider_error, "Ollama streaming failed: #{inspect(exception)}")
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
    ndjson_state = NDJSON.new()
    acc = StreamAccumulator.new()
    stream_receive_loop(async, ndjson_state, acc, caller, ref)
  end

  defp process_stream_body(body, caller, ref) when is_binary(body) do
    ndjson_state = NDJSON.new()
    {events, ndjson_state} = NDJSON.parse(ndjson_state, body)
    {remaining, _ndjson_state} = NDJSON.flush(ndjson_state)
    all_events = events ++ remaining

    acc = StreamAccumulator.new()
    acc = process_ndjson_events(all_events, acc, caller, ref)
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
         ndjson_state,
         acc,
         caller,
         ref
       ) do
    receive do
      {^async_ref, {:data, chunk}} ->
        {events, ndjson_state} = NDJSON.parse(ndjson_state, chunk)
        acc = process_ndjson_events(events, acc, caller, ref)
        stream_receive_loop(async, ndjson_state, acc, caller, ref)

      {^async_ref, :done} ->
        {remaining, _ndjson_state} = NDJSON.flush(ndjson_state)
        acc = process_ndjson_events(remaining, acc, caller, ref)
        finalize_stream(acc, caller, ref)
        :ok

      {^async_ref, {:error, reason}} ->
        error = Error.new(:streaming_error, "Stream error: #{inspect(reason)}")
        send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})
        :ok
    after
      300_000 ->
        error = Error.new(:timeout, "Ollama stream receive timed out after 300s")
        send(caller, {Agora.Stream, ref, StreamEvent.error(error)})
        send(caller, {Agora.Stream, ref, StreamEvent.done()})
        :ok
    end
  end

  defp process_ndjson_events(events, acc, caller, ref) do
    Enum.reduce(events, acc, fn event, acc ->
      handle_ollama_event(event, acc, caller, ref)
    end)
  end

  defp handle_ollama_event(%{"done" => true} = event, acc, _caller, _ref) do
    metadata = acc.metadata

    metadata =
      metadata
      |> maybe_put(:model, event["model"])
      |> maybe_put(:stop_reason, event["done_reason"])
      |> maybe_put(:total_duration, event["total_duration"])
      |> maybe_put(:load_duration, event["load_duration"])
      |> maybe_put(:prompt_eval_count, event["prompt_eval_count"])
      |> maybe_put(:prompt_eval_duration, event["prompt_eval_duration"])
      |> maybe_put(:eval_count, event["eval_count"])
      |> maybe_put(:eval_duration, event["eval_duration"])

    %{acc | metadata: metadata}
  end

  defp handle_ollama_event(%{"message" => message_data} = _event, acc, caller, ref) do
    acc = handle_content(message_data, acc, caller, ref)
    handle_tool_calls(message_data, acc, caller, ref)
  end

  defp handle_ollama_event(_other, acc, _caller, _ref), do: acc

  defp handle_content(%{"content" => content}, acc, caller, ref)
       when is_binary(content) and content != "" do
    event = StreamEvent.text_delta(content)
    send(caller, {Agora.Stream, ref, event})
    StreamAccumulator.apply(acc, event)
  end

  defp handle_content(_message_data, acc, _caller, _ref), do: acc

  defp handle_tool_calls(%{"tool_calls" => tool_calls}, acc, caller, ref)
       when is_list(tool_calls) do
    tc_offset = map_size(acc.tool_calls)

    tool_calls
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {tc, local_index}, acc ->
      func = tc["function"] || %{}
      global_index = tc_offset + local_index
      id = "ollama_tc_#{global_index}"
      name = func["name"]
      args = normalize_arguments(func["arguments"])

      start_event = StreamEvent.tool_call_start(id, name, global_index)
      send(caller, {Agora.Stream, ref, start_event})
      acc = StreamAccumulator.apply(acc, start_event)

      args_json = Jason.encode!(args)
      delta_event = StreamEvent.tool_call_delta(id, args_json)
      send(caller, {Agora.Stream, ref, delta_event})
      StreamAccumulator.apply(acc, delta_event)
    end)
  end

  defp handle_tool_calls(_message_data, acc, _caller, _ref), do: acc

  defp finalize_stream(acc, caller, ref) do
    message = StreamAccumulator.to_message(acc)
    send(caller, {Agora.Stream, ref, StreamEvent.message_complete(message)})
    send(caller, {Agora.Stream, ref, StreamEvent.done()})
  end

  defp normalize_error_body(%Req.Response.Async{}), do: %{}

  defp normalize_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"error" => body}
    end
  end

  defp normalize_error_body(body) when is_map(body), do: body
  defp normalize_error_body(_), do: %{}
end
