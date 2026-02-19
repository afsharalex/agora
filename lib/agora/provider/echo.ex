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

  alias Agora.{AgentConfig, Error, Message, Provider, ToolCall}

  @impl true
  def chat(messages, %AgentConfig{} = config) do
    mode = Provider.get_provider_opt(config, :echo_mode, :echo)
    handle_mode(mode, messages, config)
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
end
