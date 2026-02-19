defmodule Agora.Provider.Anthropic do
  @moduledoc """
  Provider implementation for the Anthropic Messages API.

  Translates Agora messages to the Anthropic format and handles the response.
  Supports system message extraction, tool use, and adjacent role merging.
  """

  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Config, Error, Message, ToolCall}

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
end
