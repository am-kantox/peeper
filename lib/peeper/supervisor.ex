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

  def state(pid), do: child(pid, Peeper.State, true)
  def worker(pid), do: child(pid, Peeper.Worker, true)

  @doc """
  Lists the children, awaiting for all to be restarted successfully.
  """
  def which_children(pid) do
    case Supervisor.which_children(pid) do
      [{kind1, pid1, :worker, _}, {kind2, pid2, :worker, _}] when is_pid(pid1) and is_pid(pid2) ->
        %{kind1 => pid1, kind2 => pid2}

      _ ->
        which_children(pid)
    end
  end

  # [
  #   {Peeper.Worker, #PID<0.158.0>, :worker, [Peeper.Worker]},
  #   {Peeper.State, #PID<0.157.0>, :worker, [Peeper.State]}
  # ]
  defp child(pid, kind, safe?)

  defp child(pid, kind, true) do
    pid
    |> which_children()
    |> Map.fetch!(kind)
  end

  # defp child(pid, kind, false) do
  #   pid
  #   |> Supervisor.which_children()
  #   |> Enum.find_value(fn
  #     {^kind, pid, :worker, [^kind]} -> pid
  #     _ -> nil
  #   end)
  # end
end
