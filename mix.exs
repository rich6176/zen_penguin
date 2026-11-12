defmodule ZenPenguin.MixProject do
  use Mix.Project

  def project do
    [
      app: :zen_penguin,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 100]],
      deps: deps()
    ]
  end

  def cli do
    [
      preferred_envs: [
        credo: :test,
        "deps.audit": :test
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  def application do
    [
      extra_applications: [:logger, :eex]
    ]
  end
end
