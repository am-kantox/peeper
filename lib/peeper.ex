defmodule Peeper do
  @moduledoc """
  Documentation for `Peeper`.
  """

  defmodule Empty do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(_), do: :ignore
  end

  def call(pid, msg, timeout \\ 5_000) do
    GenServer.call(worker(pid), msg, timeout)
  end

  def cast(pid, msg) do
    GenServer.cast(worker(pid), msg)
  end

  def send(pid, msg) do
    Kernel.send(worker(pid), msg)
  end

  defp worker(pid), do: Peeper.Supervisor.worker(pid)
end
