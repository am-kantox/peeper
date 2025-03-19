defmodule Peeper.Worker do
  @moduledoc false

  require Logger

  use GenServer, restart: :permanent

  def start_link(opts) do
    {impl, opts} = Keyword.pop!(opts, :impl)
    {supervisor, opts} = Keyword.pop!(opts, :supervisor)
    {opts, []} = Keyword.pop!(opts, :opts)
    {keep_ets, opts} = Keyword.pop(opts, :keep_ets, [])
    {listener, opts} = Keyword.pop(opts, :listener)

    opts =
      with true <- Keyword.has_key?(opts, :name),
           name when not is_nil(name) <-
             opts |> Keyword.fetch!(:name) |> Peeper.gen_server_name(),
           do: Keyword.put(opts, :name, name),
           else: (_ -> opts)

    GenServer.start_link(
      __MODULE__,
      %{impl: impl, listener: listener, supervisor: supervisor, keep_ets: keep_ets},
      opts
    )
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
    {cached_state, cached_ets, cached_dictionary} =
      state.supervisor
      |> Peeper.Supervisor.state()
      |> GenServer.call(:state)

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

    listener_impls =
      if Code.ensure_loaded?(state.listener) do
        Map.new(Peeper.Listener.behaviour_info(:callbacks), fn {fun, arity} ->
          {:"#{fun}?", function_exported?(state.listener, fun, arity)}
        end)
      else
        Map.new(Peeper.Listener.behaviour_info(:callbacks), fn {fun, _arity} ->
          {:"#{fun}?", false}
        end)
      end

    :ok = load_ets(cached_ets)
    :ok = load_dictionary(cached_dictionary)

    state =
      state
      |> Map.put(:state, cached_state)
      |> Map.put(:impl_funs, impl_funs)
      |> Map.put(:listener_impls, listener_impls)

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

      :ok =
        GenServer.cast(
          pid,
          {:set_state, self(), {state.state, dump_ets(state), dump_dictionary()}}
        )
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

  def handle_info({:"ETS-TRANSFER", tid, from, heir_data}, state) do
    Logger.debug(
      "ETS transfer (WORKER) ‹" <> inspect(tid: tid, heir_data: heir_data, state: state) <> "›"
    )

    case Peeper.Supervisor.state(state.supervisor) do
      ^from -> {:noreply, state}
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
  def terminate(reason, state) do
    if state.listener_impls.on_terminate?,
      do: spawn(fn -> state.listener.on_terminate(reason, state.state) end)

    do_terminate(reason, state.state)
  end

  defp do_terminate(reason, state) when state.impl_funs.terminate?,
    do: state.impl.terminate(reason, state.state)

  defp do_terminate(reason, state), do: Peeper.Empty.terminate(reason, state)

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

  defp do_store_state(%{supervisor: sup} = worker_state, state) do
    with pid when is_pid(pid) <- Peeper.Supervisor.state(sup) do
      GenServer.cast(
        pid,
        {:set_state, self(), {state, dump_ets(worker_state), dump_dictionary()}}
      )
    end

    if worker_state.listener_impls.on_state_changed?,
      do: spawn(fn -> worker_state.listener.on_state_changed(worker_state.state, state) end)

    %{worker_state | state: state}
  end

  @spec load_ets([{term(), [atom() | {atom(), term()}], [tuple()]}]) :: :ok
  defp load_ets([_ | _] = ets) do
    Enum.each(ets, fn {name, opts, content} ->
      name |> :ets.new(opts) |> tap(&:ets.insert(&1, content))
    end)
  end

  defp load_ets(_), do: :ok

  defp dump_ets(%{keep_ets: false}), do: []

  defp dump_ets(%{supervisor: sup, keep_ets: keep_ets}) do
    Enum.flat_map(:ets.all(), fn table ->
      info = :ets.info(table)
      name = Keyword.fetch!(info, :name)

      if Keyword.fetch!(info, :owner) == self() and
           (keep_ets == :all or keep_ets == true or (is_list(keep_ets) and name in keep_ets)),
         do: [info_to_content(sup, name, info)],
         else: []
    end)
  end

  @spec load_dictionary([{term(), term()}]) :: :ok
  defp load_dictionary([_ | _] = dictionary) do
    Enum.each(dictionary, fn {key, value} -> Process.put(key, value) end)
  end

  defp load_dictionary(_), do: :ok

  defp dump_dictionary do
    Process.get_keys()
    |> Enum.filter(
      &(&1 not in [
          {:elixir, :eval_env},
          :"$ancestors",
          :"$initial_call",
          :iex_evaluator,
          :iex_history,
          :iex_server,
          :elixir_checker_info
        ])
    )
    |> Enum.map(&{&1, Process.get(&1)})
  end

  defp info_to_content(sup, name, info) do
    table = Keyword.fetch!(info, :id)

    opts =
      Enum.reduce(info, [], fn
        {:protection, value}, acc -> [value | acc]
        {:type, type}, acc -> [type | acc]
        {:named_table, true}, acc -> [:named_table | acc]
        {:keypos, keypos}, acc -> [{:keypos, keypos} | acc]
        {:heir, ^sup}, acc -> [{:heir, sup} | acc]
        {:heir, :none}, acc -> acc
        # [AM] warn here
        {:heir, pid}, acc when is_pid(pid) -> acc
        {:decentralized_counters, _} = dc, acc -> [dc | acc]
        {:read_concurrency, _} = rc, acc -> [rc | acc]
        {:write_concurrency, _} = wc, acc -> [wc | acc]
        {:compressed, true}, acc -> [:compressed | acc]
        _, acc -> acc
      end)

    content = table |> :ets.match(:"$1") |> List.flatten()
    {name, opts, content}
  end
end
