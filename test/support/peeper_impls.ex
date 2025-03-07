defmodule Peeper.Impls.Empty do
  @moduledoc false

  use Peeper.GenServer
end

defmodule Peeper.Impls.Full do
  @moduledoc false

  use Peeper.GenServer

  def init(state) do
    {:ok, state} |> IO.inspect(label: "init")
  end

  def handle_info(:inc, state), do: {:noreply, state + 1} |> IO.inspect(label: "handle_info")

  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:raise, _from, _state) do
    raise "boom"
  end

  def handle_cast(:inc, state),
    do: {:noreply, state, {:continue, :inc}} |> IO.inspect(label: "handle_cast")

  def handle_continue(:inc, state),
    do: {:noreply, state + 1} |> IO.inspect(label: "handle_continue")
end
