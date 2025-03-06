defmodule Peeper.State do
  @moduledoc false

  use GenServer, restart: :permanent

  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  @impl GenServer
  def init(state), do: {:ok, Map.new(state)}

  @impl GenServer
  def handle_call(:state, {pid, _tag}, state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid -> {:reply, state.state, state}
      _ -> {:reply, :hidden, state}
    end
  end

  @impl GenServer
  def handle_cast({:set_state, pid, new_state}, state) do
    case Peeper.Supervisor.worker(state.supervisor) do
      ^pid -> {:noreply, Map.put(state, :state, new_state)}
      _ -> {:noreply, state}
    end
  end
end
