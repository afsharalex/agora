import Config

if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :agora, anthropic_api_key: api_key
end

if api_key = System.get_env("OPENAI_API_KEY") do
  config :agora, openai_api_key: api_key
end

if api_key = System.get_env("GOOGLE_API_KEY") do
  config :agora, google_api_key: api_key
end

if api_key = System.get_env("GEMINI_API_KEY") do
  config :agora, gemini_api_key: api_key
end

if api_key = System.get_env("OLLAMA_API_KEY") do
  config :agora, ollama_api_key: api_key
end
