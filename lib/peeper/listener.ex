defmodule Peeper.Listener do
  @moduledoc """
  The listener that might be implemented and attached to the `Peeper.GenServer`
    to receive notifications about process state changes and/or terminations.
  """

  @doc "Called when the underlying `Peeper.GenServer` gets terminated"
  @callback on_terminate(reason, state :: term()) :: :ok
            when reason: :normal | :shutdown | {:shutdown, term()} | term()

  @doc "Called when the underlying `Peeper.GenServer`’s state gets changed"
  @callback on_state_changed(old_state :: term(), state :: term()) :: :ok

  @optional_callbacks on_terminate: 2, on_state_changed: 2
end
