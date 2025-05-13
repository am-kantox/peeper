defmodule Peeper.Supervisor do
  @moduledoc """
  Supervisor for the Peeper framework that manages the state-preserving GenServer processes.

  ## Overview

  The `Peeper.Supervisor` is a key component in the Peeper architecture, responsible for:

  1. Creating and supervising a supervision tree for each Peeper.GenServer instance
  2. Managing the relationship between the worker process and state keeper process
  3. Ensuring state is preserved between crashes
  4. Handling process transfers between supervisors

  ## Supervision Strategy

  By default, `Peeper.Supervisor` uses a `:one_for_one` supervision strategy with the following configuration:

  * `max_restarts`: 1,000 (number of restarts allowed in a time period)
  * `max_seconds`: 10 (the time period for max_restarts)
  * `auto_shutdown`: `:never` (supervisor won't shut down automatically when a child terminates)

  This strategy allows individual worker processes to crash and be restarted independently,
  while the state keeper process remains alive to provide the preserved state on restart.

  ## Children

  The supervisor manages two worker processes:

  1. `Peeper.State` - Preserves the state between crashes
  2. `Peeper.Worker` - The actual GenServer implementation that delegates to your module

  ## State Preservation Mechanism

  When a worker process crashes:

  1. The supervisor detects the crash and initiates a restart
  2. The new worker process starts and requests its previous state from the state keeper
  3. The state keeper provides the preserved state
  4. The worker process resumes operation with the preserved state

  This handshake between the worker and state keeper happens transparently and enables 
  the "Let It Crash" philosophy without losing valuable state.

  ## Configuration

  When starting a Peeper.Supervisor, you can provide the following configuration options:

  * `strategy`: The restart strategy (default: `:one_for_one`)
  * `max_restarts`: Maximum number of restarts allowed in a time period (default: 1,000)
  * `max_seconds`: The time period for max_restarts (default: 10)
  * `auto_shutdown`: Supervisor shutdown behavior when a child terminates (default: `:never`)

  ## Internal Architecture

  ```
  Peeper.Supervisor (one_for_one)
  ├── Peeper.State (preserves state)
  └── Peeper.Worker (runs user callbacks)
      └── User's Peeper.GenServer implementation
  ```

  This modular architecture allows for:
  * Independent restart of workers without losing state
  * Clean separation of concerns
  * ETS table preservation between crashes
  * Process dictionary persistence
  """

  use Supervisor

  alias Peeper.{State, Worker}

  @doc """
  Starts a supervisor linked to the current process.

  ## Options

  * `name`: Name to register the supervisor (required)
  * `impl`: The module implementing Peeper.GenServer callbacks (required)
  * `state`: Initial state for the GenServer (required)
  * `strategy`, `max_restarts`, `max_seconds`, `auto_shutdown`: 
      Standard supervisor configuration options
  * Any other options are passed to the Worker process

  ## Returns

  * `{:ok, pid}` if the supervisor is started successfully
  * `{:error, {:already_started, pid}}` if the supervisor is already started
  * `{:error, term}` if supervision setup fails
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {sup_opts, opts} =
      Keyword.split(opts, [:strategy, :max_restarts, :max_seconds, :auto_shutdown])

    {impl, opts} = Keyword.pop!(opts, :impl)
    {state, opts} = Keyword.pop!(opts, :state)

    children = [
      {State, state: state, supervisor: self()},
      {Worker, impl: impl, opts: opts, supervisor: self()}
    ]

    Supervisor.init(
      children,
      Keyword.merge(
        [strategy: :one_for_one, max_restarts: 1_000, max_seconds: 10, auto_shutdown: :never],
        sup_opts
      )
    )
  end

  @doc """
  Gets the PID of the state keeper process for the given Peeper supervisor.

  ## Parameters

  * `pid`: PID or registered name of the Peeper supervisor
  * `delay`: Optional delay in milliseconds before attempting to get the state keeper PID

  ## Returns

  PID of the state keeper process
  """
  def state(pid, delay \\ 0), do: child(pid, Peeper.State, true, delay)

  @doc """
  Gets the PID of the worker process for the given Peeper supervisor.

  This function is useful when you need to interact directly with the worker GenServer
  process using standard GenServer functions, bypassing Peeper's wrappers.

  ## Parameters

  * `pid`: PID or registered name of the Peeper supervisor
  * `delay`: Optional delay in milliseconds before attempting to get the worker PID

  ## Returns

  PID of the worker process

  ## Example

  ```elixir
  # Get the worker pid and use it directly with GenServer
  worker_pid = Peeper.Supervisor.worker(my_peeper_process)
  GenServer.call(worker_pid, :message)
  ```
  """
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
  _doc = """
  Helper function to get a child of the supervisor by its kind.

  This is a private implementation function used by `state/2` and `worker/2`.
  """

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
