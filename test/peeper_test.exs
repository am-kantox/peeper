defmodule PeeperTest do
  use ExUnit.Case
  doctest Peeper
  use Mneme

  @tag :capture_log
  test "delegates calls and casts property" do
    pid = start_supervised!({Peeper.Impls.Full, state: 0, name: Peeper})

    assert 0 == Peeper.call(pid, :state)
    assert :ok == Peeper.cast(pid, :inc)
    assert 1 == Peeper.call(pid, :state)
    # Peeper.call(pid, :raise)
    Process.exit(pid, :raise)
    assert 1 == Peeper.call(Peeper, :state)
    assert :inc == Peeper.send(pid, :inc)
    assert 2 == Peeper.call(Peeper, :state)
  end
end
