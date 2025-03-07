defmodule Peeper.Supervisor do
  @moduledoc false

  use Supervisor

  alias Peeper.{State, Worker}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    {impl, opts} = Keyword.pop!(opts, :impl)
    {state, opts} = Keyword.pop!(opts, :state)

    children = [
      {State, state: state, supervisor: self()},
      {Worker, impl: impl, opts: opts, supervisor: self()}
    ]

    opts = Keyword.take(opts, [:strategy, :max_restarts, :max_seconds, :auto_shutdown, :name])

    Supervisor.init(
      children,
      Keyword.merge(
        [strategy: :one_for_one, max_restarts: 3, max_seconds: 5, auto_shutdown: :never],
        opts
      )
    )
  end

  def state(pid), do: child(pid, Peeper.State)
  def worker(pid), do: child(pid, Peeper.Worker)

  # [
  #   {Peeper.Worker, #PID<0.158.0>, :worker, [Peeper.Worker]},
  #   {Peeper.State, #PID<0.157.0>, :worker, [Peeper.State]}
  # ]
  defp child(pid, kind) do
    pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^kind, pid, :worker, [^kind]} -> pid
      _ -> nil
    end)
  end
end
