defmodule Peeper.GenServer do
  @moduledoc """
  A drop-in replacement for `use GenServer` that preserves state between crashes.

  ## Overview

  `Peeper.GenServer` enables you to create GenServer-like processes that maintain their state
  even when they crash. It accomplishes this through a specialized supervision tree that includes:

  1. A worker process (implementing your callbacks)
  2. A state keeper process (that preserves state between crashes)
  3. A supervisor process (managing the relationship between the worker and state keeper)

  ## Comparison with Standard GenServer

  `Peeper.GenServer` supports all the standard GenServer callbacks with nearly identical
  semantics, but with two important differences:

  1. The `init/1` callback can only return one of:
     * `{:ok, state}`
     * `{:ok, state, timeout | :hibernate | {:continue, term()}}`

  2. You must use the `Peeper` module's communication functions:
     * `Peeper.call/3` instead of `GenServer.call/3`
     * `Peeper.cast/2` instead of `GenServer.cast/2`
     * `Peeper.send/2` instead of direct process messaging

  ## State Preservation Mechanism

  When the worker process crashes, the supervisor restarts it, and the state keeper
  provides the most recent state to the restarted worker. This makes the `init/1` callback
  function primarily important only during the first start - subsequent restarts will
  override whatever state is set in `init/1` with the preserved state.

  ## Performance Considerations

  Since `Peeper.GenServer` creates three processes instead of one, it introduces some
  overhead compared to a standard GenServer. Use it when state preservation between crashes
  outweighs the need for absolute performance in highly concurrent applications.

  ## Advanced Features

  * **ETS Table Preservation**: Peeper can preserve ETS tables between crashes
  * **Process Dictionary Preservation**: Process dictionary entries are also preserved
  * **Listeners**: Attach listeners to monitor state changes and termination events
  * **Dynamic Supervisor Transfer**: Move Peeper processes between supervisors

  ## Usage

  Use `Peeper.GenServer` by adding it to your module:

  ```elixir
  defmodule MyStatePreservingServer do
    use Peeper.GenServer
    
    # Define your callbacks similar to GenServer
  end
  ```

  See the examples below for more detailed usage patterns.
  """

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
  Initializes the GenServer state.

  This callback serves a similar purpose to `c:GenServer.init/1` but has more restricted
  return values. Unlike standard GenServer's init/1, in Peeper.GenServer:

  * It may only return `{:ok, state}` or `{:ok, state, timeout | :hibernate | {:continue, term()}}`
  * It can't return `:ignore` or `{:stop, reason}`
  * It can't use other GenServer init/1 patterns like `{:ok, state, {:continue, term()}}`

  ## State Preservation Behavior

  It's important to understand that:

  1. During the first start, the state you set in init/1 becomes the initial state
  2. During restarts after crashes, the state from init/1 will be immediately overridden
     by the state preserved in the Peeper state keeper process
  3. The continued_arg in `{:continue, continued_arg}` is still respected on all starts

  ## Examples

  ```elixir
  # Basic initialization
  @impl Peeper.GenServer
  def init(args) do
    state = %{counter: 0, config: Keyword.get(args, :config, %{})}
    {:ok, state}
  end

  # Initialization with continue
  @impl Peeper.GenServer
  def init(args) do
    {:ok, args, {:continue, :load_initial_data}}
  end
  ```

  _See:_ `c:GenServer.init/1` for more details on the standard GenServer behavior.
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

  ## Customization Options

  When using `Peeper.GenServer`, you can pass options that will be applied as defaults 
  in all `start_link/1` calls:

  * `listener`: A module implementing the `Peeper.Listener` behaviour
  * `keep_ets`: Whether to preserve ETS tables between crashes (`true`, `:all`, or a list of table names)
  * Any other options that would be valid for `start_link/1`

  ## What's Injected

  Using this macro injects the following functions into your module:

  * `start_link/1`: For starting the Peeper process
  * `child_spec/1`: For use in supervision trees
  * `stop/3`: For stopping the Peeper process

  ## Basic Example

  ```elixir
  defmodule Counter do
    use Peeper.GenServer

    @impl Peeper.GenServer
    def init(_) do
      {:ok, 0}  # Initial state is 0
    end

    @impl Peeper.GenServer
    def handle_call(:get, _from, state) do
      {:reply, state, state}
    end

    @impl Peeper.GenServer
    def handle_cast(:inc, state) do
      {:noreply, state + 1}
    end
    
    @impl Peeper.GenServer
    def handle_cast({:add, n}, state) do
      {:noreply, state + n}
    end
  end
  ```

  ## Example with Listener

  ```elixir
  defmodule MyListener do
    @behaviour Peeper.Listener
    
    @impl Peeper.Listener
    def on_state_changed(old_state, new_state) do
      # Log, send telemetry event, etc.
      IO.puts("State changed from \#{inspect(old_state)} to \#{inspect(new_state)}")
      :ok
    end
    
    @impl Peeper.Listener
    def on_terminate(reason, final_state) do
      IO.puts("Process terminated with reason: \#{inspect(reason)}")
      IO.puts("Final state was: \#{inspect(final_state)}")
      :ok
    end
  end

  defmodule MyGenServer do
    use Peeper.GenServer, listener: MyListener
    
    @impl Peeper.GenServer
    def init(args) do
      {:ok, args}
    end
    
    # ... other callbacks ...
  end
  ```

  ## Example with ETS Table Preservation

  ```elixir
  defmodule CacheServer do
    use Peeper.GenServer, keep_ets: true
    
    @impl Peeper.GenServer
    def init(_) do
      # Create an ETS table that will be preserved across crashes
      :ets.new(:cache, [:named_table, :set, :public])
      {:ok, %{last_updated: nil}}
    end
    
    @impl Peeper.GenServer
    def handle_call({:get, key}, _from, state) do
      result = :ets.lookup(:cache, key)
      {:reply, result, state}
    end
    
    @impl Peeper.GenServer
    def handle_cast({:set, key, value}, state) do
      :ets.insert(:cache, {key, value})
      {:noreply, %{state | last_updated: System.monotonic_time()}}
    end
    
    # Even if this process crashes, the ETS table will be preserved
  end
  ```
  """
  defmacro __using__(opts \\ []) do
    quote generated: true, bind_quoted: [opts: opts] do
      import Kernel, except: [send: 2]

      @behaviour Peeper.GenServer

      @doc """
      Starts a `Peeper` sub-supervision process tree linked to the current process.

      ## Options

      * `state`: The initial state of the GenServer (required if not a keyword list)
      * `name`: Optional name to register the process (atom, {:global, term} or {:via, module, term})
      * `listener`: A module implementing the `Peeper.Listener` behaviour
      * `keep_ets`: `true`, `:all`, or a list of ETS table names to preserve between crashes

      ### Supervisor Configuration

      * `strategy`: The restart strategy (default: `:one_for_all`)
      * `max_restarts`: Maximum number of restarts allowed in a time period (default: 3)
      * `max_seconds`: The time period for max_restarts (default: 5)
      * `auto_shutdown`: When a child process terminates, whether to automatically terminate 
        the supervisor and all other children (default: `:never`)

      ## Returns

      * `{:ok, pid}` if the server is started successfully
      * `{:error, {:already_started, pid}}` if the server is already started
      * `{:error, term}` if the server failed to start
      """
      def start_link(opts) do
        opts = Keyword.merge(unquote(Macro.escape(opts)), opts)
        Peeper.GenServer.start_link(__MODULE__, opts)
      end

      @doc """
      Builds and overrides a child specification for use in a supervision tree.

      ## Options

      All the same options as `start_link/1` plus standard child_spec override options:

      * `id`: The identifier for the child (default: the module name)
      * `restart`: When the child should be restarted (`:permanent`, `:temporary`, `:transient`)
      * `shutdown`: How to shut down the child (`:brutal_kill`, `:infinity`, or milliseconds)
      * `type`: The type of process (`:worker` or `:supervisor`)
      * `modules`: A list of modules used by the child, defaults to `[module]`
      * `significant`: Whether the child is significant (boolean)

      ## Returns

      A child specification map that can be used in a supervision tree.

      ## Example

      ```elixir
      # In a supervisor
      children = [
        {MyPeeperGenServer, [state: initial_state, name: MyRegisteredName]},
        # ... other children
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
      ```

      _See:_ `Supervisor.child_spec/2` for more details.
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

      This function stops the entire Peeper supervision tree, including the worker process
      and the state keeper process. For proper cleanup, this should be used instead of
      directly killing individual processes.

      ## Parameters

      * `pid`: The PID or registered name of the Peeper process
      * `reason`: Shutdown reason (default: `:normal`)
      * `timeout`: How long to wait for shutdown (default: `:infinity`)

      ## Returns

      * `:ok` if the server terminates normally
      * `{:error, :not_found}` if the server is not found
      * `{:error, :timeout}` if the server does not terminate within the timeout

      ## Example

      ```elixir
      # Stop a Peeper process with default parameters
      MyServer.stop(pid)

      # Stop with custom reason and timeout
      MyServer.stop(MyRegisteredName, :shutdown, 5000)
      ```
      """
      def stop(pid, reason \\ :normal, timeout \\ :infinity),
        do: Supervisor.stop(pid, reason, timeout)
    end
  end

  @doc """
  Starts a `Peeper` sub-supervision process tree linked to the current process.

  This is the underlying implementation function called by the module-specific `start_link/1`
  that gets injected when using `use Peeper.GenServer`. It properly formats the options
  and delegates to `Peeper.Supervisor.start_link/1`.

  ## Parameters

  * `module`: The module that implements the `Peeper.GenServer` behaviour
  * `opts`: Options for initializing and configuring the Peeper supervision tree

  ## Options

  * Any non-keyword argument is treated as the initial state
  * If a keyword, it may include:
    * `state`: The initial state value
    * `listener`: Module implementing the `Peeper.Listener` behaviour
    * Any other valid options for `Peeper.Supervisor.start_link/1`

  ## Returns

  * `{:ok, pid}` if the server is started successfully
  * `{:error, reason}` if the server failed to start

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
