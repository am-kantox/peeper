defmodule Peeper.Worker do
  @moduledoc false

  use GenServer, restart: :permanent

  def start_link(opts) do
    {supervisor, opts} = Keyword.pop!(opts, :supervisor)
    {impl, opts} = Keyword.pop!(opts, :impl)
    {opts, []} = Keyword.pop!(opts, :opts)

    GenServer.start_link(__MODULE__, %{impl: impl, supervisor: supervisor}, opts)
  end

  @impl GenServer
  def init(state) do
    {:ok, state, {:continue, :__init__}}
  end

  @impl GenServer
  def handle_continue(:__init__, state) do
    cached_state =
      with pid <- Peeper.Supervisor.state(state.supervisor) do
        GenServer.call(pid, :state)
      end

    impl_funs =
      %{
        handle_call?: function_exported?(state.impl, :handle_call, 3),
        handle_cast?: function_exported?(state.impl, :handle_cast, 2),
        handle_info?: function_exported?(state.impl, :handle_info, 2),
        handle_continue?: function_exported?(state.impl, :handle_continue, 2)
      }
      |> IO.inspect(label: "IMPLS")

    state =
      state
      |> Map.put(:state, cached_state)
      |> Map.put(:impl_funs, impl_funs)

    {:noreply, state, {:continue, :__monitor_state__}}
  end

  def handle_continue(:__monitor_state__, state) do
    with pid <- Peeper.Supervisor.state(state.supervisor) do
      Process.monitor(pid)
      _old_state = GenServer.cast(pid, {:set_state, self(), state.state})
    end

    {:noreply, state}
  end

  def handle_continue(continue_arg, state) when state.impl_funs.handle_continue? do
    continue_arg
    |> state.impl.handle_continue(state.state)
    |> store_state(state)
  end

  def handle_continue(_continue_arg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, from, _reason}, state) do
    case Peeper.Supervisor.state(state.supervisor) do
      ^from -> {:noreply, state, {:continue, :__monitor_state__}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(msg, state) when state.impl_funs.handle_info? do
    msg
    |> state.impl.handle_info(state.state)
    |> store_state(state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:__state__, {from, _}, state) do
    case Peeper.Supervisor.state(state.supervisor) do
      ^from -> {:reply, state.state, state}
      _ -> {:reply, :hidden, state}
    end
  end

  def handle_call(msg, from, state) when state.impl_funs.handle_call? do
    msg
    |> state.impl.handle_call(from, state.state)
    |> store_state(state)
  end

  def handle_call(msg, from, state) do
    IO.inspect(msg: msg, from: from, state: state)
    {:reply, :not_implemented, state}
  end

  @impl GenServer
  def handle_cast(msg, state) when state.impl_funs.handle_cast? do
    msg
    |> state.impl.handle_cast(state.state)
    |> store_state(state)
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  defp store_state({:noreply, state}, worker_state),
    do: {:noreply, do_store_state(worker_state, state)}

  defp store_state({:noreply, state, args}, worker_state),
    do: {:noreply, do_store_state(worker_state, state), args}

  defp store_state({:stop, reason, state}, worker_state),
    do: {:stop, reason, do_store_state(worker_state, state)}

  defp store_state({:reply, reply, state}, worker_state),
    do: {:reply, reply, do_store_state(worker_state, state)}

  defp store_state({:reply, reply, state, args}, worker_state),
    do: {:reply, reply, do_store_state(worker_state, state), args}

  defp store_state({:stop, reason, reply, state}, worker_state),
    do: {:stop, reason, reply, do_store_state(worker_state, state)}

  defp store_state(_worker_state, unknown),
    do: unknown

  defp do_store_state(%{state: state} = worker_state, state), do: worker_state

  defp do_store_state(%{supervisor: sup} = worker_state, state) do
    with pid when is_pid(pid) <- Peeper.Supervisor.state(sup),
         do: GenServer.cast(pid, {:set_state, self(), state})

    %{worker_state | state: state}
  end
end
