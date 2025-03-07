defmodule Peeper.Worker do
  @moduledoc false

  use GenServer, restart: :permanent

  def start_link(opts) do
    {impl, opts} = Keyword.pop!(opts, :impl)
    {supervisor, opts} = Keyword.pop!(opts, :supervisor)
    {opts, []} = Keyword.pop!(opts, :opts)

    GenServer.start_link(__MODULE__, %{impl: impl, supervisor: supervisor}, opts)
  end

  @impl GenServer
  def init(state), do: {:ok, state, {:continue, :__init__}}

  @impl GenServer
  def code_change(old_vsn, state, extra) when state.impl_funs.code_change? do
    old_vsn
    |> state.impl.code_change(state.state, extra)
    |> store_state(state)
  end

  def code_change(old_vsn, state, extra), do: Peeper.Empty.code_change(old_vsn, state, extra)

  @impl GenServer
  def format_status(status), do: status

  @impl GenServer
  def handle_continue(:__init__, state) do
    cached_state =
      with pid <- Peeper.Supervisor.state(state.supervisor) do
        GenServer.call(pid, :state)
      end

    impl_funs =
      %{
        code_change?: function_exported?(state.impl, :code_change, 3),
        # format_status?: function_exported?(state.impl, :format_status, 1),
        handle_call?: function_exported?(state.impl, :handle_call, 3),
        handle_cast?: function_exported?(state.impl, :handle_cast, 2),
        handle_continue?: function_exported?(state.impl, :handle_continue, 2),
        handle_info?: function_exported?(state.impl, :handle_info, 2),
        init?: function_exported?(state.impl, :init, 1),
        terminate?: function_exported?(state.impl, :terminate, 2)
      }

    state =
      state
      |> Map.put(:state, cached_state)
      |> Map.put(:impl_funs, impl_funs)

    state =
      case handle_init(state) do
        {:ok, state} ->
          state

        other ->
          message = """
          function init/1 required by behaviour Peeper.GenServer (in module #{inspect(state.impl)}) \
          differs from `init/1` callback in GenServer. It cannot return anything but `{:ok, new_state}` tuple.

          We are to discard the value returned and make no modifications to the state, please make sure \
          you either return an `{:ok, new_state}` tuple from Peeper.GenServer.init/1 callback or switch \
          back to the bare GenServer if you really need to return anything else.

          Got: #{inspect(other)}
          """

          IO.warn(message, __ENV__)
          state
      end

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

  defp handle_init(state) when state.impl_funs.init? do
    state.state
    |> state.impl.init()
    |> store_state(state)
  end

  defp handle_init(state), do: {:ok, state}

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

  def handle_info(msg, state), do: Peeper.Empty.handle_info(msg, state)

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

  def handle_call(msg, from, state), do: Peeper.Empty.handle_call(msg, from, state)

  @impl GenServer
  def handle_cast(msg, state) when state.impl_funs.handle_cast? do
    msg
    |> state.impl.handle_cast(state.state)
    |> store_state(state)
  end

  def handle_cast(msg, state), do: Peeper.Empty.handle_cast(msg, state)

  @impl GenServer
  def terminate(reason, state) when state.impl_funs.terminate?,
    do: state.impl.terminate(reason, state.state)

  def terminate(reason, state), do: Peeper.Empty.terminate(reason, state)

  #############################################################################

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

  defp store_state({:ok, state}, worker_state),
    do: {:ok, do_store_state(worker_state, state)}

  defp store_state({:error, reason}, _worker_state),
    do: {:error, reason}

  defp store_state(unknown, _worker_state),
    do: unknown

  defp do_store_state(%{state: state} = worker_state, state), do: worker_state

  defp do_store_state(%{supervisor: sup} = worker_state, state) do
    with pid when is_pid(pid) <- Peeper.Supervisor.state(sup),
         do: GenServer.cast(pid, {:set_state, self(), state})

    %{worker_state | state: state}
  end
end
