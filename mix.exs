defmodule RiptideExecutor.MixProject do
  use Mix.Project

  def project do
    [
      app: :riptide_executor,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RiptideExecutor.Application, []}
    ]
  end

  defp deps do
    [
      {:slipstream, "~> 1.1"},
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:mint, "~> 1.10.2", override: true},
      {:ex_keccak, "~> 0.7"},
      {:ex_secp256k1, "~> 0.7"}
    ]
  end
end

