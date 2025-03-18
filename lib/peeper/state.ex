defmodule Peeper.State do
  @moduledoc false

  use GenServer, restart: :permanent

  defstruct state: nil, supervisor: nil, ets: %{}

  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  @impl GenServer
  def init(state), do: {:ok, struct!(__MODULE__, state)}

  @impl GenServer
  def handle_call(:state, {pid, _tag}, state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid -> {:reply, {state.state, state.ets}, state}
      _ -> {:reply, :hidden, state}
    end
  end

  @impl GenServer
  def handle_cast({:set_state, pid, {new_state, nil}}, %Peeper.State{} = state) do
    handle_cast({:set_state, pid, {new_state, state.ets}}, state)
  end

  def handle_cast(
        {:set_state, _pid, {state, ets}},
        %Peeper.State{state: state, ets: ets} = unchanged
      ),
      do: {:noreply, unchanged}

  def handle_cast(
        {:set_state, pid, {old_state, new_ets}},
        %Peeper.State{state: old_state} = state
      ) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid -> {:noreply, %Peeper.State{state | ets: new_ets}}
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:set_state, pid, {new_state, old_ets}}, %Peeper.State{ets: old_ets} = state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid -> {:noreply, %Peeper.State{state | state: new_state}}
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:set_state, pid, {new_state, new_ets}}, %Peeper.State{} = state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid -> {:noreply, %Peeper.State{state | ets: new_ets, state: new_state}}
      _ -> {:noreply, state}
    end
  end
end
