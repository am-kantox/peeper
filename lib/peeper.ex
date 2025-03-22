defmodule Peeper do
  @moduledoc """
  `Peeper.GenServer` is an almost drop-in replacement for `GenServer` that preserves the state
    between crashes. All the callbacks from `GenServer` are supported.

  Internally it creates a sub-supervision tree with an actual worker that delegates to the
    implementation and a state keeper. That said, it creates three processes instead of one,
    and this should be considered when building a very concurrent applications.

  The main use-case would be a long-lived `GenServer` process with no error path handling at all
    (yeah, that famous _Let It Crash_.) Using this abstraction, one is free to send unexpected
    messages to the process, raise from its `handle_×××` clauses and whatnot.

  There are two differencies compared to bare `GenServer`. `init/1` callback cannot return anything
    but `{:ok, state}` or `{:ok, new_state, timeout() | :hibernate | {:continue, term()}` tuples
    (this might have changed in the future,) and `Peeper.{call/3,cast/2,send/2}` is to be used
    instead of `GenServer.{call/3,cast/2}` and `Kernel.send/2` (this is not gonna change.)

  Please note, that whatever is set in `init/1` callback as a state, will be overriden by
    the latest state available upon restarts. That being said, `init/1` would play its role
    in setting the state during the first run only. 

  Instead of using `Peeper`’s counterparts, one might either name the process and use `Name.GenServer`
    as a name of the underlying `GenServer` or get the `GenServer`’s `pid` via `Peeper.gen_server/1`
    and use `GenServer.{call/3,cast/2}` with it.

  ### Example

      iex> {:ok, pid} = Peeper.Impls.Full.start_link(state: 0, name: Counter)
      ...> Peeper.call(pid, :state)
      0
      iex> Peeper.cast(pid, :inc)
      :ok
      iex> GenServer.call(Peeper.gen_server(Counter), :state)
      1
      iex> Peeper.call(pid, :state)
      1
      iex> # emulate crash
      ...> Process.exit(Peeper.Supervisor.worker(pid), :raise)
      ...> %{} = Peeper.Supervisor.which_children(pid)
      iex> Peeper.call(Counter, :state)
      1
      iex> Peeper.send(pid, :inc)
      :inc
      iex> Peeper.call(Counter, :state)
      2

  ### `start_link/1`

  The function receives either an initial `state`, or a keyword having keys
    `state` and (optionally) `name`. Also this keyword might have a configuration
    for the top supervisor (keys: `[:strategy, :max_restarts, :max_seconds, :auto_shutdown]`.)

  All other values passed would be re-passed to the underlying `GenServer`’s options.

  ### Keeping ETS

  `Peeper` can preserve ETS tables created by the wrapped process between crashes in several ways.

  The proper solution would be to add a `:heir` option to the ETS created by the process as

  ```elixir
  :ets.new(name, [:private, :ordered_set, Peeper.heir(MyNamedPeeper)])
  ```

  That way the ETS will remain private and not readable by any other part of the system, although
    it’ll be preserved between crashes _and_ might be transferred to another dynamic supervisor (see below.)

  If for some reason setting `:heir` explicitly is not an option, one might pass 
    `keep_ets: true | :all | [ets_name()]` option to `Peeper.start_link/1`. It’s not efficient, because
    ETS content will be passed tyo the backing state process every time the change to it happens to occur.

  If the ETS created by the underlined process has `{:heir, other_process_pid()}` set, ithe behaviour
    after a process crash is undefined, because ETS will be transferred to another process and reach out
    of the control of `Peeper`.

  ### Moving to another `DynamicSupervior`

  The `Peeper` branch might be transferred an a whole to another dynamic supervisor in the following way

  ```elixir
  Peeper.transfer(MyNamedPeeper, source_dynamic_supervisor, target_dynamic_supervisor)
  ```

  The `target_dynamic_supervisor` might be a remote `pid`, in such a case `Peeper` must be compiled 
    and loaded on the target node.

  ### Listener

  One might pass `listener: MyListener` key to `PeeperImpl.start_link/1` where `MyListener`
    should be an implementation of `Peeper.Listener` behaviour. The callbacks will be called
    when the state of the underlying behaviour is _changed_ and on termination respectively.

  That might be a good place to attach telemetry events, or logs, or whatnot.
  """

  @async_delay 0

  defmodule Empty do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(init_arg), do: {:ok, init_arg}
  end

  @typedoc "The name of the processes branch"
  @type name :: atom()

  @typedoc "The option accepted by `:ets.new/2`"
  @type ets_option ::
          {:type, :ets.table_type()}
          | :public
          | :protected
          | :private
          | :named_table
          | {:keypos, pos_integer()}
          | {:heir, pid(), term()}
          | {:heir, :none}
          | {:write_concurrency, boolean() | :auto}
          | {:read_concurrency, boolean()}
          | {:decentralized_counters, boolean()}
          | :compressed

  @doc """
  Starts a supervisor branch with the given options.
  """
  defdelegate start_link(opts), to: Peeper.Supervisor

  @doc """
  Returns a specification to start a branch under a supervisor.
  """
  defdelegate child_spec(opts), to: Peeper.Supervisor

  @doc """
  The counterpart for `GenServer.call/3`. Uses the very same semantics.
  """
  @spec call(name() | pid(), term(), timeout()) :: term()
  def call(pid, msg, timeout \\ 5_000) do
    GenServer.call(gen_server(pid), msg, timeout)
  catch
    :exit, {:noproc, {GenServer, :call, _args}} ->
      call(pid, msg, timeout)
  end

  @doc """
  The counterpart for `GenServer.cast/2`. Uses the very same semantics.
  """
  @spec cast(name() | pid(), term()) :: :ok
  def cast(pid, msg, delay \\ @async_delay) do
    pid
    |> gen_server()
    |> GenServer.cast(msg)
    |> tap(fn _ -> Process.sleep(delay) end)
  end

  @doc """
  The counterpart for `Kernel.send/2`. Uses the very same semantics.
  """
  @spec send(name() | pid(), msg) :: msg when msg: term()
  def send(pid, msg, delay \\ @async_delay) do
    pid
    |> gen_server()
    |> Kernel.send(msg)
    |> tap(fn _ -> Process.sleep(delay) end)
  end

  @doc """
  Transfers the whole `Peeper` branch from one supervisor to another.
  """
  @spec transfer(
          peeper :: name(),
          source :: Supervisor.supervisor(),
          destination :: Supervisor.supervisor(),
          return_fun? :: boolean()
        ) :: nil | (-> nil | DynamicSupervisor.on_start_child()) | term()
  def transfer(name, source_pid, destination_pid, return_fun? \\ false)

  def transfer(name, source_pid, destination_pid, true) do
    name
    |> Peeper.Supervisor.state()
    |> GenServer.call({:transfer, name, source_pid, destination_pid})
  end

  def transfer(name, source_pid, destination_pid, false) do
    name
    |> transfer(source_pid, destination_pid, true)
    |> Task.async()
    |> Task.await()
  end

  @doc """
  Returns the `pid` of the actual `GenServer`. Might be used to
  avoid the necessity of calling other functions in this module.

  The `pid` returned might be used directly in calls to
  `GenServer.{call/3,cast/2}` and/or `Kernel.send/2`
  """
  @spec gen_server(name() | pid()) :: pid()
  def gen_server(pid, delay \\ @async_delay), do: Peeper.Supervisor.worker(pid, delay)

  @doc """
  Returns a `{:heir, pid(), heir_data}` tuple where `pid` is the
  pid of the state holder. Useful when the `GenServer`
  process creates persistent _ETS_, the result of this function is
  to be passed to _ETS_ options as a config parameter.

  In that case, the tables will be given away to the state process
  and then retaken by the restarted `GenServer`.
  """
  @spec heir(name() | pid(), heir_data) :: {:heir, pid(), heir_data} when heir_data: term()
  def heir(pid, heir_data \\ nil),
    do: {:heir, Peeper.Supervisor.state(pid, @async_delay), heir_data}

  @doc """
  Tries to produce a name for the underlying `GenServer` process.
  Succeeds if the name passed to `start_link/1` of the implementation
  is an `atom()`, `{:global, atom()}`, or `{:via, module(), atom()}`.

  In such a case, the underlying `GenServer` module receives the name
  `Module.concat(name, GenServer)` and might be used as such.
  """
  @spec gen_server_name(name() | pid() | nil) :: name() | nil
  def gen_server_name(nil), do: nil

  def gen_server_name(peeper_name) when is_atom(peeper_name),
    do: Module.concat(peeper_name, GenServer)

  def gen_server_name({:global, peeper_name}) when is_atom(peeper_name),
    do: {:global, Module.concat(peeper_name, GenServer)}

  def gen_server_name({:via, registry, peeper_name}) when is_atom(peeper_name),
    do: {:via, registry, Module.concat(peeper_name, GenServer)}

  def gen_server_name(_), do: nil
end
