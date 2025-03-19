defmodule Peeper.State do
  @moduledoc false
  require Logger

  use GenServer, restart: :permanent

  defstruct supervisor: nil, state: nil, ets: [], dictionary: [], heired: []

  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  @impl GenServer
  def init(state), do: {:ok, struct!(__MODULE__, state)}

  @impl GenServer
  def handle_call(:state, {pid, _tag}, state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid ->
        Enum.each(state.heired, fn {tid, heir_data} ->
          Logger.debug(
            "Giving away ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
          )

          :ets.give_away(tid, pid, heir_data)
        end)

        {:reply, {state.state, state.ets, state.dictionary}, %Peeper.State{state | heired: []}}

      _ ->
        {:reply, :hidden, state}
    end
  end

  @impl GenServer
  def handle_cast(
        {:set_state, _pid, {state, ets, dictionary}},
        %Peeper.State{state: state, ets: ets, dictionary: dictionary} = unchanged
      ),
      do: {:noreply, unchanged}

  def handle_cast(
        {:set_state, pid, {new_state, new_ets, new_dictionary}},
        %Peeper.State{} = state
      ) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid ->
        {:noreply,
         %Peeper.State{state | state: new_state, ets: new_ets, dictionary: new_dictionary}}

      _ ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:"ETS-TRANSFER", tid, _from_pid, heir_data}, state) do
    Logger.debug(
      "ETS transfer (STATE) ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
    )

    {:noreply, %Peeper.State{state | heired: Enum.uniq([{tid, heir_data} | state.heired])}}
  end
end
