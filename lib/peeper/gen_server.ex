defmodule Peeper.GenServer do
  @moduledoc false

  @callback code_change(old_vsn, state :: term, extra :: term) ::
              {:ok, new_state :: term}
              | {:error, reason :: term}
            when old_vsn: term | {:down, term}

  @callback handle_call(request :: term, GenServer.from(), state :: term) ::
              {:reply, reply, new_state}
              | {:reply, reply, new_state,
                 timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:stop, reason, reply, new_state}
              | {:stop, reason, new_state}
            when reply: term, new_state: term, reason: term

  @callback handle_cast(request :: term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @callback handle_continue(continue_arg, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg}}
              | {:stop, reason :: term, new_state}
            when new_state: term, continue_arg: term

  @callback handle_info(msg :: :timeout | term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @callback init(init_arg :: term) :: {:ok, new_state} when new_state: term

  @callback terminate(reason, state :: term) :: term
            when reason: :normal | :shutdown | {:shutdown, term} | term

  @optional_callbacks code_change: 3,
                      handle_call: 3,
                      handle_cast: 2,
                      handle_continue: 2,
                      handle_info: 2,
                      init: 1,
                      terminate: 2

  defmacro __using__(opts \\ []) do
    quote generated: true, bind_quoted: [opts: opts] do
      import Kernel, except: [send: 2]

      @behaviour Peeper.GenServer

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

      def child_spec(opts) do
        default = %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end
    end
  end
end
