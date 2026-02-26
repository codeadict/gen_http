# This file is only used when gen_http is pulled as a dependency
# from a Mix project. Use rebar3 for compiling, running tests, etc.
defmodule GenHttp.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()
  @source_url "https://github.com/codeadict/gen_http"

  def project do
    [
      app: :gen_http,
      version: @version,
      language: :erlang,
      description: "Erlang native HTTP client with support for HTTP/1 and HTTP/2.",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end
end
