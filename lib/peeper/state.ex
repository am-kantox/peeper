defmodule Peeper.State do
  @moduledoc false
  require Logger

  use GenServer, restart: :permanent

  @state_ets :peeper_state_ets

  defstruct supervisor: nil, state_ets: nil, heired: []

  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  @impl GenServer
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

    # [AM] maybe optionally keep all the intermediate states with `bag`?
    state_ets =
      :ets.new(@state_ets, [
        :private,
        :ordered_set,
        write_concurrency: :auto,
        read_concurrency: true
      ])

    true = :ets.insert(state_ets, {:state, state})
    true = :ets.insert(state_ets, {:dictionary, dictionary})
    {heired, ets} = split_peeper_heirs(ets)
    true = :ets.insert(state_ets, {:ets, ets})

    {:ok, struct!(__MODULE__, supervisor: supervisor, state_ets: state_ets, heired: heired)}
  end

  @impl GenServer
  def handle_call(:state, {pid, _tag}, %Peeper.State{state_ets: ets} = state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid ->
        state.heired
        |> fix_peeper_heirs(pid)
        |> Enum.each(fn {tid, heir_data} ->
          Logger.debug(
            "Giving away ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
          )

          :ets.give_away(tid, pid, heir_data)
        end)

        worker_state = :ets.lookup_element(ets, :state, 2)
        worker_dictionary = :ets.lookup_element(ets, :dictionary, 2)

        worker_ets =
          ets
          |> :ets.lookup_element(:ets, 2)
          |> filter_peeper_heirs()

        {:reply, {worker_state, worker_ets, worker_dictionary}, %Peeper.State{state | heired: []}}

      _ ->
        {:reply, :hidden, state}
    end
  end

  def handle_call({:move, name, from_dynamic_supervisor, to_dynamic_supervisor}, _from, state) do
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
        _ -> nil
      end

    {:reply, task, state}
  end

  @impl GenServer
  def handle_cast(
        {:set_state, pid, {new_state, new_ets, new_dictionary}},
        %Peeper.State{state_ets: ets} = state
      ) do
    with ^pid <- Peeper.Supervisor.worker(state.supervisor) do
      true = :ets.insert(ets, {:state, new_state})
      true = :ets.insert(ets, {:dictionary, new_dictionary})
      true = :ets.insert(ets, {:ets, new_ets})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:"ETS-TRANSFER", tid, _from_pid, heir_data}, state) do
    Logger.debug(
      "ETS transfer (STATE) ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
    )

    {:noreply, %Peeper.State{state | heired: Enum.uniq([{tid, heir_data} | state.heired])}}
  end

  defp filter_peeper_heirs([]), do: []

  defp filter_peeper_heirs(ets),
    do: Enum.reject(ets, fn {_name, opts, _data} -> Enum.member?(opts, {:heir, :peeper}) end)

  defp split_peeper_heirs(ets) do
    Enum.reduce(ets, {[], []}, fn {_, opts, _} = table, {heired, rest} ->
      if Enum.member?(opts, {:heir, :peeper}),
        do: {[table | heired], rest},
        else: {heired, [table | rest]}
    end)
  end

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
