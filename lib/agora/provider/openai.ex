defmodule Agora.Provider.OpenAI do
  @moduledoc """
  Provider implementation for the OpenAI Chat Completions API.

  Translates Agora messages to the OpenAI format and handles the response.
  Supports inline system messages, JSON string tool arguments, and
  tool result expansion.
  """

  @behaviour Agora.Provider

  alias Agora.{AgentConfig, Config, Error, Message, ToolCall}

  @default_base_url "https://api.openai.com"
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

    maybe_add_tools(body, config.tools)
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
            "name" => to_string(tool[:name] || tool["name"]),
            "description" => tool[:description] || tool["description"] || "",
            "parameters" =>
              tool[:parameters] || tool[:input_schema] || tool["parameters"] ||
                tool["input_schema"] || %{}
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
end
