defmodule Peeper.Impls.Listener do
  @moduledoc false

  @behaviour Peeper.Listener

  require Logger

  @impl true
  def on_state_changed(old_state, state) do
    [old: old_state, new: state] |> inspect() |> Logger.info()
  end

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
    {:ok, state} |> IO.inspect(label: "init")
  end

  @impl Peeper.GenServer
  def handle_info(:inc, state), do: {:noreply, state + 1} |> IO.inspect(label: "handle_info")

  @impl Peeper.GenServer
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:raise, _from, _state) do
    raise "boom"
  end

  @impl Peeper.GenServer
  def handle_cast(:inc, state),
    do: {:noreply, state, {:continue, :inc}} |> IO.inspect(label: "handle_cast")

  @impl Peeper.GenServer
  def handle_continue(:inc, state),
    do: {:noreply, state + 1} |> IO.inspect(label: "handle_continue")
end
