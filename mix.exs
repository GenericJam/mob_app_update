defmodule MobAppUpdate.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_app_update"

  def project do
    [
      app: :mob_app_update,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description:
        "Self-update for Mob Android apps from GitHub Releases: check, download with sha256 verification, user-confirmed install",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      source_url: @source_url
    ]
  end

  def application do
    # :inets (httpc) + :ssl reach GitHub; listed so a Mob release bundles them.
    [extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push
    # and the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    [
      {:mob, "~> 0.9"},
      {:mob_dev, "~> 0.7", only: [:dev, :test], runtime: false},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob core's pre-commit gate.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The native sources + manifest must ship in the package — the host's
      # native build compiles them from deps/<plugin>/priv.
      files: ~w(lib src priv mix.exs README* CHANGELOG* LICENSE*)
    ]
  end
end
