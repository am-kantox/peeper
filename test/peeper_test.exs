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
    peeper_pid = start_supervised!(Peeper.child_spec(impl: Peeper.Impls.Full, state: 0, name: P2))
    pid = Peeper.gen_server(peeper_pid)

    assert 0 == GenServer.call(pid, :state)
    assert :ok == GenServer.cast(pid, :inc)
    assert 1 == GenServer.call(pid, :state)
    Process.exit(pid, :kill)
    assert 1 == Peeper.call(P2, :state)
    assert :inc == Peeper.send(P2, :inc)
    assert 2 == GenServer.call(Peeper.gen_server(peeper_pid), :state)
  end

  test "restores ETSs and process dictionary" do
    {:ok, source_pid} = DynamicSupervisor.start_link(name: SDS)

    {:ok, pid} =
      DynamicSupervisor.start_child(SDS, {Peeper.Impls.Full, state: 0, name: P3, keep_ets: true})

    assert 0 == Peeper.call(pid, :state)
    # assert :ok == Peeper.cast(pid, {:create_ets, :my_ets})
    # assert :ok == Peeper.cast(pid, {:create_heired_ets, :my_heired_ets, P3, %{foo: 42}})
    assert :ok == Peeper.cast(pid, {:set_pd, :foo, 42})
    assert :ok == Peeper.cast(pid, :inc)
    assert 1 == Peeper.call(P3, :state)
    Process.exit(Peeper.Supervisor.worker(pid), :kill)
    assert 1 == Peeper.call(P3, :state)
    assert 42 == Peeper.call(P3, {:get_pd, :foo})
    # assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_ets})
    # assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_heired_ets})

    {:ok, target_pid} = DynamicSupervisor.start_link(name: TDS)

    pid
    |> Peeper.Supervisor.state()
    |> GenServer.call({:move, P3, source_pid, target_pid})
    |> Task.async()
    |> Task.await()

    assert [{:undefined, pid, :supervisor, _}] = DynamicSupervisor.which_children(TDS)
    assert pid == GenServer.whereis(P3)
    assert 1 == Peeper.call(P3, :state)
    assert 42 == Peeper.call(P3, {:get_pd, :foo})
    # assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_ets})
    # assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_heired_ets})
  end

  test "stress calls and casts work properly" do
    peeper_pid = start_supervised!({Peeper.Impls.Full, state: 0, name: P3})
    pid1 = Peeper.gen_server(peeper_pid)

    assert 0 == GenServer.call(pid1, :state)
    assert :ok == GenServer.cast(pid1, :inc)
    assert 1 == GenServer.call(pid1, :state)
    Process.exit(pid1, :kill)
    Process.sleep(1)

    for i <- 2..1_000 do
      pid = Peeper.gen_server(peeper_pid)
      refute pid == pid1
      assert i - 1 == GenServer.call(pid, :state)
      assert :ok == Peeper.cast(peeper_pid, :inc)
      assert i == GenServer.call(pid, :state)
      Process.exit(pid, :kill)
      Process.sleep(1)
    end

    assert 1_000 == Peeper.call(P3, :state)
  end
end
