defmodule Peeper.State do
  @moduledoc """
  Core state management module for the Peeper framework.

  This module is responsible for preserving and restoring state between crashes of
  the wrapped GenServer. It acts as a private state keeper within the Peeper supervision
  tree, storing the latest state of the GenServer implementation.

  ## Role in Supervision Tree

  `Peeper.State` is a child process in the Peeper supervision tree, started directly 
  under the main `Peeper.Supervisor`. It maintains:

  1. The current state of the wrapped GenServer
  2. Any ETS tables created by the process that need to be preserved
  3. The process dictionary content that needs to be restored after crashes

  ## Internal Functionality

  When the worker GenServer crashes and is restarted by the supervisor, it
  retrieves its last known state from this state keeper process. This allows
  the GenServer to maintain state continuity despite crashes, implementing the
  "Let It Crash" philosophy without losing valuable state.

  This module also handles:
  - ETS table ownership transfers between the worker and state processes
  - Process migration between supervisors (including remote nodes)
  - Storage of process dictionary data

  This is an internal module that shouldn't be used directly by client code.
  Instead, interact with Peeper through the public API in the `Peeper` module.
  """
  require Logger

  use GenServer, restart: :permanent

  # Name of the ETS table used internally to store state, process dictionary, and ETS records
  @state_ets :peeper_state_ets

  @typedoc """
  Represents a serialized ETS table dump consisting of:
  - The table name or identifier
  - A list of table options (access, heir, etc.)
  - The actual table data as a list of tuples

  This format allows ETS tables to be recreated with identical configuration
  and data after a worker process crash.
  """
  @type ets_dump :: {Peeper.name(), [Peeper.ets_option()], [tuple()]}

  defstruct supervisor: nil, state_ets: nil, heired: []

  @doc """
  Starts a State GenServer process linked to the current process.

  This function is called by the Peeper.Supervisor to initialize the state keeper
  that will preserve state between worker restarts.

  ## Parameters

  - `state`: A keyword list containing initialization parameters with the following keys:
    - `:supervisor`: PID of the parent supervisor (required)
    - `:state`: The initial state to be stored (optional)
    - `:ets`: ETS tables to be preserved (optional)
    - `:dictionary`: Process dictionary content to preserve (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  @impl GenServer
  @doc """
  Initializes the State GenServer with the provided state information.

  This function:
  1. Extracts the supervisor PID and any initial state data
  2. Sets up the internal ETS table to store state, dictionary, and ETS tables data
  3. Processes any inherited ETS tables that need special handling

  The internal ETS table structure contains three key-value pairs:
  - {:state, state} - The actual application state to be preserved
  - {:dictionary, dictionary} - Process dictionary entries to be restored
  - {:ets, ets} - ETS tables information for recreation after a crash
  """
  def init(state) do
    {supervisor, state} = Keyword.pop!(state, :supervisor)
    {state, _opts} = Keyword.pop(state, :state, [])

    {state, ets, dictionary} =
      if Keyword.keyword?(state) and Keyword.has_key?(state, :state) do
        {ets, state} = Keyword.pop(state, :ets, [])
        {dictionary, state} = Keyword.pop(state, :dictionary, [])
        {state, []} = Keyword.pop(state, :state, nil)
        {state, ets, dictionary}
      else
        {state, [], []}
      end

    # Create an internal ETS table to store the preserved state
    # Note: Using :ordered_set for consistent access patterns and overwrites.
    # [AM] maybe optionally keep all the intermediate states with `bag`?
    state_ets =
      :ets.new(@state_ets, [
        # Only accessible by this process
        :private,
        # Maintains one value per key in sorted order
        :ordered_set,
        # Automatic write concurrency setting
        write_concurrency: :auto,
        # Optimize for concurrent reads
        read_concurrency: true
      ])

    # Store the initial state in the ETS table
    true = :ets.insert(state_ets, {:state, state})

    # Store any process dictionary entries that need to be restored on restart
    true = :ets.insert(state_ets, {:dictionary, dictionary})

    # Split ETS tables into those with Peeper-specific heir settings and others
    {heired, ets} = split_peeper_heirs(ets)

    # Store regular ETS tables information for recreation after crashes
    true = :ets.insert(state_ets, {:ets, ets})

    {:ok, struct!(__MODULE__, supervisor: supervisor, state_ets: state_ets, heired: heired)}
  end

  @impl GenServer
  _doc = """
  Handles the `:state` call from a worker process, returning the preserved state.

  This callback is triggered when a worker process (after restart) requests its state.
  It verifies that the caller is the legitimate worker process, then returns:
  - The preserved GenServer state
  - Any ETS tables that need to be restored
  - Process dictionary items to be reinstated

  It also handles giving away any inherited ETS tables back to the worker process.
  """

  @doc false
  @spec handle_call(:state, {pid(), term()}, %__MODULE__{}) ::
          {:reply, {term(), [ets_dump()], keyword()} | :hidden, %__MODULE__{}}
  def handle_call(:state, {pid, _tag}, %Peeper.State{state_ets: ets} = state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid ->
        # Process any inherited ETS tables and transfer them back to the worker
        # This handles tables that were taken over when the previous worker crashed
        state.heired
        # Prepare tables for transfer to worker
        |> fix_peeper_heirs(pid)
        |> Enum.each(fn {tid, heir_data} ->
          Logger.debug(
            "Giving away ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
          )

          # Transfer table ownership to the new worker process
          :ets.give_away(tid, pid, heir_data)
        end)

        # Retrieve the preserved application state to send to the worker
        worker_state = :ets.lookup_element(ets, :state, 2)

        # Retrieve process dictionary entries to restore in the worker
        worker_dictionary = :ets.lookup_element(ets, :dictionary, 2)

        # Retrieve ETS table specifications, filtering out Peeper-managed tables
        # (those are handled separately through the heir mechanism)
        worker_ets =
          ets
          # Get the list of ETS tables
          |> :ets.lookup_element(:ets, 2)
          # Remove Peeper-managed tables
          |> filter_peeper_heirs()

        {:reply, {worker_state, worker_ets, worker_dictionary}, %Peeper.State{state | heired: []}}

      _ ->
        {:reply, :hidden, state}
    end
  end

  _doc = """
  Handles process transfer requests between dynamic supervisors.

  This callback facilitates the migration of a Peeper process from one dynamic supervisor
  to another, potentially across different nodes in a distributed Erlang cluster.

  The transfer process:
  1. Retrieves the current child specification from the supervisor 
  2. Terminates the process under the source supervisor
  3. Starts a new process with the preserved state under the target supervisor

  For remote transfers, it uses `:rpc.block_call/4` to start the process on the remote node.
  """

  @spec handle_call(
          {:transfer, Peeper.name(), Supervisor.supervisor(), Supervisor.supervisor()},
          GenServer.from(),
          %__MODULE__{}
        ) :: {:reply, (-> nil | DynamicSupervisor.on_start_child()) | nil, %__MODULE__{}}
  def handle_call({:transfer, name, from_dynamic_supervisor, to_dynamic_supervisor}, _from, state) do
    worker_child_spec =
      state.supervisor
      |> Peeper.call(:__state__)
      |> Keyword.put_new(:name, name)
      |> Peeper.child_spec()

    task =
      with peeper_pid when is_pid(peeper_pid) <- GenServer.whereis(name),
           from_dynamic_supervisor_pid when is_pid(from_dynamic_supervisor_pid) <-
             GenServer.whereis(from_dynamic_supervisor),
           to_dynamic_supervisor_pid when is_pid(to_dynamic_supervisor_pid) <-
             GenServer.whereis(to_dynamic_supervisor) do
        fn ->
          with :ok <- DynamicSupervisor.terminate_child(from_dynamic_supervisor_pid, peeper_pid) do
            me = node()

            case node(to_dynamic_supervisor_pid) do
              ^me ->
                DynamicSupervisor.start_child(to_dynamic_supervisor_pid, worker_child_spec)

              remote ->
                :rpc.block_call(remote, DynamicSupervisor, :start_child, [worker_child_spec])
            end
          end
        end
      else
        _ -> fn -> nil end
      end

    {:reply, task, state}
  end

  @impl GenServer
  _doc = """
  Updates the preserved state with new values from the worker process.

  This callback is invoked when the worker process needs to update its preserved state.
  It validates that the request comes from the legitimate worker process before 
  updating the state, ETS tables, and process dictionary information in the state ETS table.
  """

  @doc false
  @spec handle_cast(
          {:set_state, pid(), {term(), [ets_dump()], keyword()}},
          %__MODULE__{}
        ) :: {:noreply, %__MODULE__{}}
  def handle_cast(
        {:set_state, pid, {new_state, new_ets, new_dictionary}},
        %Peeper.State{state_ets: ets} = state
      ) do
    # Verify the request comes from the legitimate worker process
    # This prevents unauthorized processes from modifying the preserved state
    with ^pid <- Peeper.Supervisor.worker(state.supervisor) do
      # Update the application state in our internal storage
      true = :ets.insert(ets, {:state, new_state})

      # Update the process dictionary entries
      true = :ets.insert(ets, {:dictionary, new_dictionary})

      # Update the ETS tables information
      true = :ets.insert(ets, {:ets, new_ets})
    end

    {:noreply, state}
  end

  @impl GenServer
  _doc = """
  Handles ETS table ownership transfers to the state process.

  This callback is triggered when an ETS table is transferred to this process,
  typically after a worker process crashes. It records the table and heir data
  so that the table can be transferred back to the worker when it restarts.
  """

  @doc false
  @spec handle_info({:"ETS-TRANSFER", :ets.tid(), pid(), term()}, %__MODULE__{}) ::
          {:noreply, %__MODULE__{}}
  def handle_info({:"ETS-TRANSFER", tid, _from_pid, heir_data}, state) do
    Logger.debug(
      "ETS transfer (STATE) ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
    )

    # Add the transferred table to our list of inherited tables
    # This table will be given back to the worker when it restarts
    # We use Enum.uniq to prevent duplicate entries in case of repeated transfers
    {:noreply, %Peeper.State{state | heired: Enum.uniq([{tid, heir_data} | state.heired])}}
  end

  _doc = """
  Filters out ETS tables that have Peeper-specific heir settings.

  This helper function excludes tables that are specifically marked to be
  managed by the Peeper state system (those with {:heir, :peeper} option).

  ## Why this is necessary

  Tables with Peeper-specific heir settings are handled separately through the 
  ETS table ownership transfer mechanism. These tables don't need to be recreated
  from scratch on worker restart - instead, their ownership is transferred directly.

  This function is used in `handle_call(:state, ...)` to ensure we only return
  tables that need manual recreation to the worker process.

  ## Parameters

  - `ets`: A list of ETS table specifications in the `ets_dump` format

  ## Returns

  A filtered list containing only tables without the `{:heir, :peeper}` option
  """

  @spec filter_peeper_heirs([ets_dump()]) :: [ets_dump()]
  defp filter_peeper_heirs([]), do: []

  defp filter_peeper_heirs(ets),
    do: Enum.reject(ets, fn {_name, opts, _data} -> Enum.member?(opts, {:heir, :peeper}) end)

  _doc = """
  Separates ETS tables into Peeper-managed and standard tables.

  This helper function divides the list of ETS tables into two categories:
  - Tables with the {:heir, :peeper} option (Peeper-managed)
  - Standard tables without Peeper-specific heir settings
  """

  defp split_peeper_heirs(ets) do
    Enum.reduce(ets, {[], []}, fn {_, opts, _} = table, {heired, rest} ->
      if Enum.member?(opts, {:heir, :peeper}),
        do: {[table | heired], rest},
        else: {heired, [table | rest]}
    end)
  end

  _doc = """
  Processes inherited ETS tables to prepare them for transfer back to the worker.

  This function handles two types of inputs:
  1. Already existing ETS tables with their heir data
  2. ETS table specifications that need to be recreated

  For recreated tables, it:
  - Creates a new ETS table with the same options
  - Populates it with the original data
  - Sets the worker process as the heir

  Returns a list of tuples with {table_id, heir_data} for all tables ready for transfer.
  """

  @spec fix_peeper_heirs([{:ets.tid(), term()} | ets_dump()], pid()) :: [{:ets.tid(), term()}]
  defp fix_peeper_heirs(heired_ets, pid) do
    Enum.map(heired_ets, fn
      {tid, heir_data} ->
        {tid, heir_data}

      {name, opts, data} ->
        heir_data = %{peeper: name}

        opts =
          Enum.map(opts, fn
            {:heir, :peeper} -> {:heir, pid, heir_data}
            other -> other
          end)

        {name |> :ets.new(opts) |> tap(&:ets.insert(&1, data)), heir_data}
    end)
  end
end
