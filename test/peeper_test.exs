defmodule PeeperTest do
  use ExUnit.Case
  doctest Peeper

  test "greets the world" do
    assert Peeper.hello() == :world
  end
end
