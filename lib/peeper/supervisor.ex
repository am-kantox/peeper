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
        [strategy: :one_for_one, max_restarts: 1_000, max_seconds: 10, auto_shutdown: :never],
        opts
      )
    )
  end

  def state(pid, delay \\ 0), do: child(pid, Peeper.State, true, delay)
  def worker(pid, delay \\ 0), do: child(pid, Peeper.Worker, true, delay)

  @doc """
  Lists the children, awaiting for all to be restarted successfully.
  """
  def which_children(server, delay \\ 0) do
    Process.sleep(delay)

    with [{kind1, pid1, :worker, [kind1]}, {kind2, pid2, :worker, [kind2]}]
         when is_pid(pid1) and is_pid(pid2) <-
           Supervisor.which_children(server),
         pid1 when is_pid(pid1) <- whereis(pid1),
         pid2 when is_pid(pid2) <- whereis(pid2),
         do: %{kind1 => pid1, kind2 => pid2},
         else: (_ -> which_children(server))
  end

  @doc """
  Returns a local or remote pid if the `GenServer` is alive, `nil` otherwise
  """
  @spec whereis(server :: pid() | GenServer.name() | {atom(), node()}) :: pid() | nil
  def whereis(server) do
    with {name, node} <- GenServer.whereis(server),
         do: :rpc.call(node, GenServer, :whereis, [name])
  end

  # [
  #   {Peeper.Worker, #PID<0.158.0>, :worker, [Peeper.Worker]},
  #   {Peeper.State, #PID<0.157.0>, :worker, [Peeper.State]}
  # ]
  defp child(pid, kind, safe?, delay)

  defp child(pid, kind, true, delay) do
    pid
    |> which_children(delay)
    |> Map.fetch!(kind)
  end

  # defp child(pid, kind, false, delay) do
  #   Process.sleep(delay)
  #
  #   pid
  #   |> Supervisor.which_children()
  #   |> Enum.find_value(fn
  #     {^kind, pid, :worker, [^kind]} -> pid
  #     _ -> nil
  #   end)
  # end
end
