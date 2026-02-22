defmodule Agora.Tool.Http do
  @moduledoc """
  HTTP request tool for making web API calls.

  Supports GET, POST, PUT, PATCH, DELETE, and HEAD methods via `Req`.
  Includes SSRF protection that blocks requests to private/reserved IP ranges
  and non-HTTP schemes.

  ## SSRF Protection

  Before making any request, the tool:
    * Rejects non-HTTP/HTTPS schemes (blocks `file://`, `ftp://`, etc.)
    * Resolves the hostname and checks the IP against blocked ranges:
      `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
      `169.254.0.0/16` (link-local/cloud metadata), `::1`, `fc00::/7`, `fe80::/10`

  ## Example

      config = Agora.AgentConfig.new!(
        provider: :anthropic,
        model: "claude-sonnet-4-20250514",
        tools: [Agora.Tool.Http]
      )

  """

  @behaviour Agora.Tool

  import Bitwise

  alias Agora.Tool.Schema

  @impl true
  def name, do: "http"

  @impl true
  def description,
    do: "Make HTTP requests to external APIs. Supports GET, POST, PUT, PATCH, DELETE, HEAD."

  @impl true
  def schema do
    Schema.object(
      %{
        "method" =>
          Schema.enum(["get", "post", "put", "patch", "delete", "head"],
            description: "HTTP method"
          ),
        "url" => Schema.string(description: "The URL to request"),
        "headers" => Schema.object(%{}, description: "Request headers as key-value pairs"),
        "body" => Schema.string(description: "Request body (for POST, PUT, PATCH)")
      },
      required: ["method", "url"]
    )
  end

  @impl true
  def timeout, do: 30_000

  @method_atoms %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head
  }

  @impl true
  def execute(%{"method" => method, "url" => url} = args, context) do
    # Skip SSRF validation when using a test plug (Req.Test injects a plug adapter)
    skip_ssrf? = match?(%{req_options: [{:plug, _} | _]}, context)

    with {:ok, method_atom} <- parse_method(method),
         :ok <- if(skip_ssrf?, do: :ok, else: validate_url(url)) do
      headers = parse_headers(Map.get(args, "headers", %{}))
      body = Map.get(args, "body")

      req_opts =
        [method: method_atom, url: url, headers: headers, receive_timeout: 30_000]
        |> maybe_add_body(body)
        |> maybe_add_req_options(context)

      case Req.request(req_opts) do
        {:ok, response} ->
          {:ok,
           %{
             status: response.status,
             headers: format_headers(response.headers),
             body: response.body
           }}

        {:error, exception} ->
          {:error, "HTTP request failed: #{Exception.message(exception)}"}
      end
    end
  end

  defp parse_method(method) when is_map_key(@method_atoms, method),
    do: {:ok, Map.fetch!(@method_atoms, method)}

  defp parse_method(method),
    do: {:error, "Unsupported HTTP method: #{method}"}

  defp maybe_add_body(opts, nil), do: opts
  defp maybe_add_body(opts, body), do: Keyword.put(opts, :body, body)

  defp maybe_add_req_options(opts, %{req_options: req_options}),
    do: Keyword.merge(opts, req_options)

  defp maybe_add_req_options(opts, _), do: opts

  defp parse_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp format_headers(headers) do
    Map.new(headers, fn {k, v} -> {k, v} end)
  end

  # --- SSRF Protection ---

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: nil} ->
        {:error, "Invalid URL: missing scheme"}

      %URI{host: nil} ->
        {:error, "Invalid URL: missing host"}

      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, "Unsupported URL scheme: #{scheme}. Only http and https are allowed"}

      %URI{host: host} ->
        check_host(host)
    end
  end

  defp check_host(host) do
    # Try IPv4 first, then IPv6, then DNS resolution
    host_charlist = String.to_charlist(host)

    case :inet.parse_address(host_charlist) do
      {:ok, ip} ->
        check_ip(ip, host)

      {:error, _} ->
        # Not a literal IP — resolve via DNS
        case :inet.getaddr(host_charlist, :inet) do
          {:ok, ip} ->
            check_ip(ip, host)

          {:error, _} ->
            # Try IPv6
            case :inet.getaddr(host_charlist, :inet6) do
              {:ok, ip} -> check_ip(ip, host)
              {:error, _} -> {:error, "Cannot resolve host: #{host}"}
            end
        end
    end
  end

  defp check_ip(ip, host) do
    if private_ip?(ip) do
      {:error, "Request to private/reserved IP address blocked (#{host})"}
    else
      :ok
    end
  end

  # IPv4 private/reserved ranges
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, 0, 0, 0}), do: true

  # IPv6 private/reserved ranges
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # fc00::/7 (unique local)
  defp private_ip?({a, _, _, _, _, _, _, _})
       when is_integer(a) and (a &&& 0xFE00) == 0xFC00,
       do: true

  # fe80::/10 (link-local)
  defp private_ip?({a, _, _, _, _, _, _, _})
       when is_integer(a) and (a &&& 0xFFC0) == 0xFE80,
       do: true

  defp private_ip?(_), do: false
end
