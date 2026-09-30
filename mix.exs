defmodule Flockit.MixProject do
  use Mix.Project

  @version "1.1.0"
  @source_url "https://github.com/ausimian/flockit"

  def project do
    [
      app: :flockit,
      version: System.get_env("VERSION_OVERRIDE", @version),
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      description: "Advisory file locks using flock(2), without blocking BEAM schedulers.",
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, coveralls: :test, "coveralls.html": :test]]
  end

  def application do
    [
      mod: {Flockit.Application, []},
      extra_applications: [:logger],
      env: [max_poll_interval: 250]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:publisho, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(c_src lib .formatter.exs mix.exs Makefile README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Flockit",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: @version,
      source_url: @source_url
    ]
  end
end
