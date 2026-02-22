# HTTP Tool Example
#
# Demonstrates the Http tool for making API requests with SSRF protection.
# Makes real HTTP requests to httpbin.org (a public test API) and shows
# how SSRF protection blocks requests to private IP ranges.
#
# Requires network access.
#
# Run with: mix run examples/http_tool.exs

alias Agora.Tool.Http

IO.puts("=== HTTP Tool Example ===\n")

# --- GET request ---

IO.puts("1. GET https://httpbin.org/json")

case Http.execute(%{"method" => "get", "url" => "https://httpbin.org/json"}, %{}) do
  {:ok, result} ->
    IO.puts("   Status: #{result.status}")
    IO.puts("   Content-Type: #{result.headers["content-type"]}")

    body = if is_binary(result.body), do: Jason.decode!(result.body), else: result.body
    title = get_in(body, ["slideshow", "title"])
    IO.puts("   Slideshow title: #{title}\n")

  {:error, reason} ->
    IO.puts("   Failed: #{reason}\n")
end

# --- POST request with body ---

IO.puts("2. POST https://httpbin.org/post")

post_body = Jason.encode!(%{"name" => "Alice", "role" => "engineer"})

case Http.execute(
       %{
         "method" => "post",
         "url" => "https://httpbin.org/post",
         "headers" => %{"content-type" => "application/json"},
         "body" => post_body
       },
       %{}
     ) do
  {:ok, result} ->
    IO.puts("   Status: #{result.status}")

    body = if is_binary(result.body), do: Jason.decode!(result.body), else: result.body
    IO.puts("   Echoed data: #{inspect(body["data"])}\n")

  {:error, reason} ->
    IO.puts("   Failed: #{reason}\n")
end

# --- SSRF protection ---

IO.puts("3. SSRF protection blocks private IPs and non-HTTP schemes")

{:error, reason} =
  Http.execute(
    %{"method" => "get", "url" => "http://169.254.169.254/latest/meta-data/"},
    %{}
  )

IO.puts("   Cloud metadata blocked: #{reason}")

{:error, reason} =
  Http.execute(
    %{"method" => "get", "url" => "file:///etc/passwd"},
    %{}
  )

IO.puts("   File scheme blocked: #{reason}")
