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
    {ets, state} = Keyword.pop(state, :ets, [])
    {dictionary, state} = Keyword.pop(state, :dictionary, [])
    {state, []} = Keyword.pop(state, :state, nil)
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
    true = :ets.insert(state_ets, {:ets, ets})

    {:ok, struct!(__MODULE__, supervisor: supervisor, state_ets: state_ets)}
  end

  @impl GenServer
  def handle_call(:state, {pid, _tag}, %Peeper.State{state_ets: ets} = state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid ->
        Enum.each(state.heired, fn {tid, heir_data} ->
          Logger.debug(
            "Giving away ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
          )

          :ets.give_away(tid, pid, heir_data)
        end)

        worker_state = :ets.lookup_element(ets, :state, 2)
        worker_dictionary = :ets.lookup_element(ets, :dictionary, 2)
        worker_ets = :ets.lookup_element(ets, :ets, 2)
        {:reply, {worker_state, worker_ets, worker_dictionary}, %Peeper.State{state | heired: []}}

      _ ->
        {:reply, :hidden, state}
    end
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
end
