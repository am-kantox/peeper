defmodule PeeperTest do
  use ExUnit.Case
  doctest Peeper
  use Mneme

  test "delegates calls and casts property" do
    pid = start_supervised!({Peeper.Impls.Full, state: 0, name: P1})

    assert 0 == Peeper.call(pid, :state)
    assert :ok == Peeper.cast(pid, :inc)
    assert 1 == Peeper.call(pid, :state)
    # Peeper.call(pid, :raise)
    Process.exit(Peeper.Supervisor.worker(pid), :raise)
    assert %{} = Peeper.Supervisor.which_children(pid)
    assert 1 == Peeper.call(P1, :state)
    assert :inc == Peeper.send(pid, :inc)
    assert 2 == Peeper.call(P1, :state)
  end

  test "direct calls and casts to the wrapped GenServer" do
    peeper_pid = start_supervised!({Peeper.Impls.Full, state: 0, name: P2})
    pid = Peeper.gen_server(peeper_pid)

    assert 0 == GenServer.call(pid, :state)
    assert :ok == GenServer.cast(pid, :inc)
    assert 1 == GenServer.call(pid, :state)
    # Peeper.call(pid, :raise)
    Process.exit(pid, :raise)
    assert %{} = Peeper.Supervisor.which_children(peeper_pid)
    assert 1 == Peeper.call(P2, :state)
    assert :inc == Peeper.send(P2, :inc)
    assert 2 == GenServer.call(Peeper.gen_server(peeper_pid), :state)
  end
end
