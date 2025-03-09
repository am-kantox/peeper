defmodule PeeperTest do
  use ExUnit.Case
  doctest Peeper
  use Mneme

  test "delegates calls and casts property" do
    pid = start_supervised!({Peeper.Impls.Full, state: 0, name: P1})

    assert 0 == Peeper.call(pid, :state)
    assert :ok == Peeper.cast(pid, :inc)
    assert 1 == Peeper.call(pid, :state)
    Process.exit(Peeper.Supervisor.worker(pid), :raise)
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
    Process.exit(pid, :raise)
    assert 1 == Peeper.call(P2, :state)
    assert :inc == Peeper.send(P2, :inc)
    assert 2 == GenServer.call(Peeper.gen_server(peeper_pid), :state)
  end

  test "stress calls and casts work properly" do
    peeper_pid = start_supervised!({Peeper.Impls.Full, state: 0, name: P3})
    pid1 = Peeper.gen_server(peeper_pid)

    assert 0 == GenServer.call(pid1, :state)
    assert :ok == GenServer.cast(pid1, :inc)
    assert 1 == GenServer.call(pid1, :state)
    Process.exit(pid1, :raise)

    for _ <- 2..100 do
      pid = Peeper.gen_server(peeper_pid)
      refute pid == pid1
      assert :ok == Peeper.cast(peeper_pid, :inc)
      Process.exit(pid, :raise)
    end

    assert 100 == Peeper.call(P3, :state)
  end
end
