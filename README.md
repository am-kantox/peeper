# Peeper

**Almost drop-in replacement for `GenServer` that preserves state between crashes.** **State Preservation**: Maintain process state even when crashes occur
* **ETS Table Preservation**: Keep ETS tables alive between process restarts
* **Process Dictionary Preservation**: Preserve process dictionary entries between crashes
* **GenServer Compatible**: Use familiar GenServer callbacks and patterns
* **Supervision Tree Integration**: Works within existing supervision hierarchies
* **Listener Hooks**: Attach listeners to monitor state changes and termination events
* **Dynamic Supervisor Transfer**: Move Peeper processes between supervisors (even across nodes)

## How It Works

`Peeper.GenServer` is an almost drop-in replacement for `GenServer` that preserves state between crashes. All the callbacks from `GenServer` are supported.

Internally, Peeper creates a specialized supervision tree with:

1. A worker process (implementing your callbacks, similar to a regular GenServer)
2. A state keeper process (that preserves state between crashes)
3. A supervisor process (managing the relationship between the worker and state keeper)

This architecture allows Peeper to capture and restore state automatically when the worker process crashes, making it ideal for long-lived processes where you want to embrace the _"Let It Crash"_ philosophy without losing valuable state.

## Comparison with Standard GenServer

Peeper maintains compatibility with GenServer while adding state persistence. There are two main differences:

1. **Restricted `init/1` callback**: It can only return `{:ok, state}` or `{:ok, state, timeout | :hibernate | {:continue, term()}}` tuples.

2. **Communication functions**: You must use:
   * `Peeper.call/3` instead of `GenServer.call/3`
   * `Peeper.cast/2` instead of `GenServer.cast/2`
   * `Peeper.send/2` instead of `Kernel.send/2`

> **Note**: Whatever is set in `init/1` callback will be overridden by the preserved state upon restarts. The `init/1` callback sets the state only during the first run.

### Alternative Communication

If you prefer standard GenServer communication functions, you can:
* Name the process and use `Name.GenServer` as the name of the underlying GenServer
* Get the worker's PID via `Peeper.gen_server/1` and use standard GenServer functions with it

## Installation

1. Add `peeper` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:peeper, "~> 0.3.0"}
  ]
end
```

2. Install the dependency:

```bash
mix deps.get
```

## Basic Usage

### Creating a Peeper.GenServer

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
end
```

### Starting and Using

```elixir
# Start the server
{:ok, pid} = Counter.start_link(name: CounterServer)

# Use the server
Peeper.call(pid, :get)  # Returns 0
Peeper.cast(pid, :inc)  # Increments counter
Peeper.call(CounterServer, :get)  # Returns 1

# Crash the server
Process.exit(Peeper.gen_server(pid), :kill)

# State is preserved after crash!
Peeper.call(CounterServer, :get)  # Still returns 1
```

### Interactive Example

```elixir
# Start with initial state 0 and registered name Counter
iex> {:ok, pid} = Peeper.Impls.Full.start_link(state: this_is_pid())

# Check the state
iex> Peeper.call(pid, :state)
0

# Update the state
iex> Peeper.cast(pid, :inc)
:ok

# State was updated
iex> Peeper.call(pid, :state)
1

# Emulate crash
iex> Process.exit(Peeper.Supervisor.worker(pid), :raise)
iex> %{} = Peeper.Supervisor.which_children(pid)

# State is preserved after crash
iex> Peeper.call(pid, :state)
1

# Continue using the server
iex> Peeper.send(pid, :inc)
:inc
iex> Peeper.call(pid, :state)
2
```

## Configuration Options

When starting a Peeper GenServer, you can provide various configuration options:

### Basic Options

* `state`: The initial state (required if not a keyword list)
* `name`: Optional name to register the process (atom, {:global, term} or {:via, module, term})

### ETS Table Options

* `keep_ets`: Options for preserving ETS tables:
  * `true`: Preserve all ETS tables owned by the process
  * `:all`: Same as `true`
  * `[table_name1, table_name2, ...]`: List of specific ETS table names to preserve

### Listener Options

* `listener`: A module implementing the `Peeper.Listener` behaviour

### Supervisor Configuration

* `strategy`: The restart strategy (default: `:one_for_all`)
* `max_restarts`: Maximum number of restarts allowed in a time period (default: 3)
* `max_seconds`: The time period for max_restarts (default: 5)
* `auto_shutdown`: When a child process terminates, whether to automatically terminate the supervisor and all other children (default: `:never`)

## Advanced Usage

### Working with ETS Tables

There are two ways to preserve ETS tables between crashes:

#### Method 1: Using `Peeper.heir/2` (Recommended)

```elixir
defmodule CacheServer do
  use Peeper.GenServer
  
  @impl Peeper.GenServer
  def init(_) do
    # Create an ETS table with Peeper as heir
    :ets.new(:my_cache, [:named_table, :set, :private, Peeper.heir(self())])
    {:ok, %{last_access: nil}}
  end
  
  # Rest of implementation...
end
```

This method is more efficient because the table ownership is transferred directly via the heir mechanism.

#### Method 2: Using `keep_ets` Option

```elixir
defmodule CacheServer do
  use Peeper.GenServer, keep_ets: true  # Can also be :all or a list of table names
  
  @impl Peeper.GenServer
  def init(_) do
    :ets.new(:my_cache, [:named_table, :set])
    {:ok, %{last_access: nil}}
  end
  
  # Rest of implementation...
end
```

This method copies the table contents to the state keeper, so it's less efficient for large tables or frequent updates.

### Using Listeners

Listeners can monitor state changes and termination events, useful for logging, telemetry, or other side effects:

```elixir
defmodule MyListener do
  @behaviour Peeper.Listener
  
  @impl Peeper.Listener
  def on_state_changed(old_state, new_state) do
    # Log state change, send metrics, etc.
    Logger.info("State changed from #{inspect(old_state)} to #{inspect(new_state)}")
    :ok
  end
  
  @impl Peeper.Listener
  def on_terminate(reason, final_state) do
    # Log termination
    Logger.info("Process terminated with reason: #{inspect(reason)}")
    :ok
  end
end

defmodule MyServer do
  use Peeper.GenServer, listener: MyListener
  
  # Implementation...
end
```

### Transferring Between Supervisors

Peeper allows transferring a process between different dynamic supervisors, even across nodes:

```elixir
# Start source and target supervisors
{:ok, source_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
{:ok, target_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

# Start a Peeper process under the source supervisor
{:ok, peeper_pid} = DynamicSupervisor.start_child(
  source_sup,
  {MyPeeperServer, state: initial_state, name: MyServer}
)

# Later, transfer the process to the target supervisor
Peeper.transfer(MyServer, source_sup, target_sup)

# The process continues running under the target supervisor with preserved state
```

## Best Practices

### When to Use Peeper

Peeper is ideal for:
* Long-running processes where state preservation is critical
* Scenarios where you want to embrace "Let It Crash" while keeping state
* Services that use ETS tables for caching or state storage
* Applications where process recovery should be transparent to clients

Not recommended for:
* Very high-throughput, performance-critical processes (due to the extra process overhead)
* Cases where state loss on crash is acceptable or desirable
* Short-lived or ephemeral processes

### Supervision Strategy

Peeper works best with the following supervision pattern:

```
Application Supervisor (one_for_one)
├── Other Workers/Supervisors
├── DynamicSupervisor
│   └── Peeper Supervision Tree
│       ├── Peeper.Supervisor
│       ├── Peeper.State (state keeper)
│       └── Your Peeper.GenServer (worker)
```

This isolation ensures that Peeper process crashes don't affect other parts of your application.

### Handling ETS Tables

* Prefer the `Peeper.heir/2` approach for ETS tables when possible
* Be cautious when setting custom heirs other than Peeper on ETS tables
* For very large tables, consider using a separate persistent storage mechanism

### State Size Considerations

* Keep your GenServer state reasonably sized - large states impact performance
* Consider using ETS tables (with Peeper's heir mechanism) for larger datasets
* For very large states, consider external persistence (database, disk)
* Avoid storing resources that can't be serialized (PIDs, ports, references) in state
* Be mindful of how state size affects message passing between processes

### Message Handling

* Implement proper timeouts in your handle_call callbacks
* Use handle_continue for breaking down complex operations
* Handle unexpected messages in handle_info to prevent crashes from stray messages

## Performance Considerations

### Process Overhead

Peeper creates three processes for each `Peeper.GenServer` (compared to one for a standard GenServer):

1. The supervisor process
2. The state keeper process
3. The worker process (your actual GenServer implementation)

This increases the memory footprint and adds some communication overhead. The impact is typically negligible for most applications but can become significant with hundreds or thousands of Peeper processes.

### State Transfer Cost

When the state changes, Peeper must transfer it to the state keeper process. This introduces a small overhead proportional to the state size. For extremely frequent state changes (thousands per second), this can impact performance.

### ETS Table Considerations

When using the `keep_ets: true` approach, Peeper copies the entire ETS table content on each state update. For large or frequently updated tables, this can be expensive.

Using the `Peeper.heir/2` approach is much more efficient as it only transfers table ownership, not content.

### Benchmarks

Some rough performance comparisons:

| Operation | Standard GenServer | Peeper.GenServer |
|-----------|-------------------|-----------------|
| Start | ~1x | ~1.5-2x slower |
| call/cast with small state | ~1x | ~1.1x slower |
| call/cast with large state | ~1x | ~1.5-2x slower |
| Process memory | ~1x | ~3x more |

For most applications, this performance difference is not significant, but it's worth considering for high-throughput services.

## Troubleshooting

### Common Issues and Solutions

#### Process Not Responding After Crash

**Problem**: After a crash, your Peeper process doesn't respond to messages.

**Possible causes**:
* Supervisor restart limit exceeded
* Invalid state that causes immediate crash on restart

**Solutions**:
* Check logs for crash reason
* Increase restart limits in supervisor configuration
* Add defensive code to handle invalid states

#### State Not Being Preserved

**Problem**: After a crash, your Peeper process starts with initial state instead of preserved state.

**Possible causes**:
* State keeper process crashed
* Supervisor was restarted completely

**Solutions**:
* Make sure you're using correct supervision strategy
* Check if the state keeper process is alive with `Peeper.Supervisor.state(pid)`

#### ETS Tables Not Being Preserved

**Problem**: ETS tables disappear after a crash despite using `keep_ets` or `Peeper.heir/2`.

**Possible causes**:
* Using the wrong table name
* Custom heir settings overriding Peeper's heir
* Table is not owned by the Peeper worker process

**Solutions**:
* Verify table ownership with `:ets.info(table_name, :owner)`
* Check that you're not setting another heir after creating the table

#### Slow Performance

**Problem**: Your Peeper implementation is slow compared to a standard GenServer.

**Possible causes**:
* Large state size
* Frequent state updates
* Many ETS tables with `keep_ets: true`

**Solutions**:
* Optimize state size
* Use `Peeper.heir/2` for ETS tables
* Consider if state preservation is necessary for this specific process

## License

MIT License - see the [LICENSE](LICENSE) file for details.

## Documentation

For more detailed documentation, visit [HexDocs](https://hexdocs.pm/peeper).

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
