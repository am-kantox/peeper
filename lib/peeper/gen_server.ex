defmodule Peeper.GenServer do
  @moduledoc false

  defmacro __using__(opts \\ []) do
    quote location: :keep, generated: true do
      import Kernel, except: [send: 2]

      def start_link(opts) do
        opts = if Keyword.keyword?(opts), do: opts, else: [state: opts]
        opts = Keyword.merge(unquote(opts), opts)
        {opts, state} = Keyword.split(opts, [:name])

        state = Keyword.get(state, :state, state)

        opts =
          opts
          |> Keyword.put(:impl, __MODULE__)
          |> Keyword.put(:state, state)

        Peeper.Supervisor.start_link(opts)
      end

      def call(pid, msg, timeout \\ 5_000) do
        worker = Peeper.Supervisor.worker(pid)
        GenServer.call(worker, msg, timeout)
      end

      def cast(pid, msg) do
        worker = Peeper.Supervisor.worker(pid)
        GenServer.cast(worker, msg)
      end

      def send(pid, msg) do
        worker = Peeper.Supervisor.worker(pid)
        Kernel.send(worker, msg)
      end
    end
  end
end
