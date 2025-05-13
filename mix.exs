defmodule Peeper.MixProject do
  use Mix.Project

  @app :peeper
  @version "0.3.1"
  @source_url "https://github.com/am-kantox/#{@app}"
  @homepage_url "https://hexdocs.pm/#{@app}"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.14",
      compilers: compilers(Mix.env()),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() not in [:dev],
      description: description(),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.json": :test,
        "coveralls.html": :test,
        "test.watch": :test
      ],
      releases: [],
      dialyzer: [
        plt_file: {:no_warn, ".dialyzer/dialyzer.plt"},
        plt_add_deps: :app_tree,
        plt_add_apps: [:mix],
        list_unused_filters: true,
        ignore_warnings: ".dialyzer/ignore.exs"
      ]
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      # Development and documentation
      {:doctest_formatter, "~> 0.2", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.28", only: [:dev], runtime: false},

      # Testing
      {:excoveralls, "~> 0.16", only: [:test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:mneme, "~> 0.6", only: [:dev, :test]},
      {:stream_data, "~> 0.5", only: [:dev, :test]},
      {:mix_test_watch, "~> 1.1", only: [:dev, :test], runtime: false},

      # Benchmarking
      {:benchee, "~> 1.1", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      # Quality checks
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": [
        "format --check-formatted",
        "credo --strict",
        "dialyzer"
      ],

      # Test aliases
      test: ["test"],
      "test.watch": ["test.watch --stale"],
      "test.all": ["coveralls.html"],

      # Documentation
      docs: ["docs", &copy_images/1],

      # Development helpers 
      setup: ["deps.get", "deps.compile"]
    ]
  end

  # Copy images from /stuff directory to /doc/assets for ex_doc
  defp copy_images(_) do
    File.mkdir_p!("doc/assets")
    File.cp_r!("stuff/images", "doc/assets")
    :ok
  end

  defp description do
    """
    Peeper is an Elixir library that provides a GenServer-like API with automatic state preservation between crashes.

    It enables you to embrace the "Let It Crash" philosophy while maintaining valuable state, supporting:
    - Transparent state recovery after process crashes
    - ETS table preservation between restarts
    - Process dictionary persistence
    - State change listeners for monitoring
    - Process migration between supervisors (including remote nodes)
    """
  end

  defp package do
    [
      name: @app,
      files: ~w|lib stuff .formatter.exs .dialyzer/ignore.exs mix.exs README* LICENSE*|,
      maintainers: ["Aleksei Matiushkin"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => @homepage_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      categories: ["OTP", "GenServer", "Fault Tolerance", "Application Lifecycle"]
    ]
  end

  defp docs do
    [
      main: "Peeper",
      source_ref: "v#{@version}",
      canonical: @homepage_url,
      logo: "stuff/#{@app}-48x48.png",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        "Core Components": [
          Peeper,
          Peeper.GenServer
        ],
        "Internal Modules": [
          Peeper.Supervisor,
          Peeper.State,
          Peeper.Worker
        ],
        Behaviours: [
          Peeper.Listener
        ]
      ],
      assets: %{"stuff/images" => "assets"}
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp compilers(_), do: Mix.compilers()
end
