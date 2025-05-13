defmodule Peeper.Impls.Listener do
  @moduledoc false

  @behaviour Peeper.Listener

  require Logger

  @impl true
  def on_terminate(reason, state) do
    [reason: reason, state: state] |> inspect() |> Logger.warning()
  end
end

defmodule Peeper.Impls.Empty do
  @moduledoc false

  use Peeper.GenServer
end

defmodule Peeper.Impls.Full do
  @moduledoc false

  # credo:disable-for-this-file Credo.Check.Warning.IoInspect

  use Peeper.GenServer, listener: Peeper.Impls.Listener

  @impl Peeper.GenServer
  def init(state) do
    name = :all_ets
    {:noreply, state} = handle_cast({:create_ets, name}, state)
    {:ok, state}
  end

  @impl Peeper.GenServer
  def handle_info(:inc, state), do: {:noreply, state + 1}

  @impl Peeper.GenServer
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:ets, name}, _from, state) do
    {:reply, :ets.match(name, :"$1"), state}
  end

  def handle_call({:get_pd, key}, _from, state) do
    {:reply, Process.get(key), state}
  end

  def handle_call(:raise, _from, _state) do
    raise "boom"
  end

  @impl Peeper.GenServer
  def handle_cast({:create_ets, name}, state) do
    with :undefined <- :ets.info(name) do
      name
      |> :ets.new([:named_table, :ordered_set])
      |> :ets.insert([{:a, 42}, {:b, :foo}, {:c, 42, :foo}])
    end

    {:noreply, state}
  end

  def handle_cast({:create_heired_ets, name, id, heir_data}, state) do
    name
    |> :ets.new([:named_table, :ordered_set, Peeper.heir(id, heir_data)])
    |> :ets.insert([{:a, 42}, {:b, :foo}, {:c, 42, :foo}])

    {:noreply, state}
  end

  def handle_cast({:set_pd, key, value}, state) do
    Process.put(key, value)
    {:noreply, state}
  end

  def handle_cast(:inc, state),
    do: {:noreply, state, {:continue, :inc}}

  @impl Peeper.GenServer
  def handle_continue(:inc, state),
    do: {:noreply, state + 1}
end
