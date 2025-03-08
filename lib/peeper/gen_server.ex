defmodule Peeper.GenServer do
  @moduledoc "A drop-in replacement for `use GenServer`"

  @doc "_See:_ `c:GenServer.code_change/3`"
  @callback code_change(old_vsn, state :: term, extra :: term) ::
              {:ok, new_state :: term}
              | {:error, reason :: term}
            when old_vsn: term | {:down, term}

  @doc "_See:_ `c:GenServer.handle_call/3`"
  @callback handle_call(request :: term, GenServer.from(), state :: term) ::
              {:reply, reply, new_state}
              | {:reply, reply, new_state,
                 timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:stop, reason, reply, new_state}
              | {:stop, reason, new_state}
            when reply: term, new_state: term, reason: term

  @doc "_See:_ `c:GenServer.handle_cast/2`"
  @callback handle_cast(request :: term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @doc "_See:_ `c:GenServer.handle_continue/2`"
  @callback handle_continue(continue_arg, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg}}
              | {:stop, reason :: term, new_state}
            when new_state: term, continue_arg: term

  @doc "_See:_ `c:GenServer.handle_info/2`"
  @callback handle_info(msg :: :timeout | term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @doc """
  Almost the same as `c:GenServer.init/1` but cannot return anything but `{:ok, new_state}`
    tuple and is being invoked from `handle_continue/2` followed `init/1` of the state
    keeper process.

  _See:_ `c:GenServer.init/1`
  """
  @callback init(init_arg :: term) :: {:ok, new_state} when new_state: term

  @doc "_See:_ `c:GenServer.terminate/2`"
  @callback terminate(reason, state :: term) :: term
            when reason: :normal | :shutdown | {:shutdown, term} | term

  @optional_callbacks code_change: 3,
                      handle_call: 3,
                      handle_cast: 2,
                      handle_continue: 2,
                      handle_info: 2,
                      init: 1,
                      terminate: 2

  @doc """
  Declares a `Peeper.GenServer` behaviour, injects `start_link/1` function
  and the child spec.

  ### Example

  ```elixir
  defmodule MyGenServer do
    use Peeper.GenServer

    @impl Peeper.GenServer
    def handle_call(:state, _from, state),
      do: {:reply, state, state}

    @impl Peeper.GenServer
    def handle_cast(:inc, state),
      do: {:noreply, state, {:continue, :inc}}

    @impl Peeper.GenServer
    def handle_continue(:inc, state),
      do: {:noreply, state + 1}
    end
  ```
  """
  defmacro __using__(opts \\ []) do
    quote generated: true, bind_quoted: [opts: opts] do
      import Kernel, except: [send: 2]

      @behaviour Peeper.GenServer

      @doc """
      Starts a `Peeper` sub-supervision process tree linked to the current process.
      """
      def start_link(opts) do
        opts = Keyword.merge(unquote(Macro.escape(opts)), opts)
        Peeper.GenServer.start_link(__MODULE__, opts)
      end

      @doc """
      Builds and overrides a child specification.

      _See:_ `Supervisor.child_spec/2`
      """
      def child_spec(opts) do
        opts = Keyword.merge(unquote(Macro.escape(opts)), opts)

        {overrides, opts} =
          Keyword.split(opts, [:restart, :shutdown, :type, :modules, :significant])

        default = %{id: __MODULE__, start: {Peeper.GenServer, :start_link, [__MODULE__, opts]}}
        Supervisor.child_spec(default, overrides)
      end

      @doc """
      Stops a `Peeper` sub-supervision tree.
      """
      def stop(pid, reason \\ :normal, timeout \\ :infinity),
        do: Supervisor.stop(pid, reason, timeout)
    end
  end

  @doc """
  Starts a `Peeper` sub-supervision process tree linked to the current process.
  """
  def start_link(module, opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: [state: opts]

    {listener, opts} = Keyword.pop(opts, :listener)

    {state, opts} =
      if Keyword.has_key?(opts, :state),
        do: Keyword.pop!(opts, :state),
        else: Keyword.split_with(opts, &(not match?({:name, _}, &1)))

    opts =
      opts
      |> Keyword.put(:impl, module)
      |> Keyword.put(:listener, listener)
      |> Keyword.put(:state, state)

    Peeper.Supervisor.start_link(opts)
  end
end
