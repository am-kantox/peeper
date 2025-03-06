defmodule Peeper do
  @moduledoc """
  Documentation for `Peeper`.
  """

  use Peeper.GenServer

  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:raise, _from, _state) do
    raise "boom"
  end

  def handle_call(msg, {from, _}, state) do
    {:reply, [msg: msg, from: from, state: state + 1], state + 1}
  end

  def handle_cast(:inc, state),
    do: {:noreply, state, {:continue, :inc}} |> IO.inspect(label: "handle_cast")

  def handle_continue(:inc, state),
    do: {:noreply, state + 1} |> IO.inspect(label: "handle_continue")
end
