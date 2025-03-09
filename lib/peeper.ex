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
    but `{:ok, state}` tuple (this might have changed in the future,) and
    `Peeper.{call/3,cast/2,send/2}` is to be used instead of `GenServer.{call/3,cast/2}` and
    `Kernel.send/2` (this is not gonna change.)

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
      iex> GenServer.call(Counter.GenServer, :state)
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

  ### Listener

  One might pass `listener: MyListener` key to `PeeperImpl.start_link/1` where `MyListener`
    should be an implementation of `Peeper.Listener` behaviour. The callbacks will be called
    when the state of the underlying behaviour is _changed_ and on termination respectively.

  That might be a good place to attach telemetry events, or logs, or whatnot.
  """

  @async_delay 1

  defmodule Empty do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(_), do: :ignore
  end

  @doc """
  The counterpart for `GenServer.call/3`. Uses the very same semantics.
  """
  def call(pid, msg, timeout \\ 5_000) do
    GenServer.call(gen_server(pid), msg, timeout)
  catch
    :exit, {:noproc, {GenServer, :call, _args}} ->
      call(pid, msg, timeout)
  end

  @doc """
  The counterpart for `GenServer.cast/2`. Uses the very same semantics.
  """
  def cast(pid, msg) do
    pid
    |> gen_server()
    |> GenServer.cast(msg)
    |> tap(fn _ -> Process.sleep(@async_delay) end)
  end

  @doc """
  The counterpart for `Kernel.send/2`. Uses the very same semantics.
  """
  def send(pid, msg) do
    pid
    |> gen_server()
    |> Kernel.send(msg)
    |> tap(fn _ -> Process.sleep(@async_delay) end)
  end

  @doc """
  Returns the `pid` of the actual `GenServer`. Might be used to
  avoid the necessity of calling other functions in this module.

  The `pid` returned might be used directly in calls to
  `GenServer.{call/3,cast/2}` and/or `Kernel.send/2`
  """
  def gen_server(pid), do: Peeper.Supervisor.worker(pid, @async_delay)

  @doc """
  Tries to produce a name for the underlying `GenServer` process.
  Succeeds if the name passed to `start_link/1` of the implementation
  is an `atom()`, `{:global, atom()}`, or `{:via, module(), atom()}`.

  In such a case, the underlying `GenServer` module receives the name
  `Module.concat(name, GenServer)` and might be used as such.
  """
  def gen_server_name(nil), do: nil

  def gen_server_name(peeper_name) when is_atom(peeper_name),
    do: Module.concat(peeper_name, GenServer)

  def gen_server_name({:global, peeper_name}) when is_atom(peeper_name),
    do: {:global, Module.concat(peeper_name, GenServer)}

  def gen_server_name({:via, registry, peeper_name}) when is_atom(peeper_name),
    do: {:via, registry, Module.concat(peeper_name, GenServer)}

  def gen_server_name(_), do: nil
end
