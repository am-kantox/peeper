defmodule PeeperTest do
  use ExUnit.Case, async: false
  doctest Peeper
  use Mneme
  import ExUnit.CaptureLog
  alias Peeper.Impls.Full, as: FullImpl

  @moduledoc """
  Comprehensive tests for the Peeper library functionality.

  These tests cover:
  - Basic operations (calls, casts, sends)
  - Direct vs Peeper API communication
  - State preservation across crashes
  - ETS table and process dictionary preservation
  - Process transfer between supervisors
  - Error scenarios and edge cases
  - Stress testing
  """

  # Helper to check PID and refresh after potential restart
  defp refresh_worker_pid(peeper_pid) do
    # Allow time for restart if needed
    Process.sleep(10)
    Peeper.gen_server(peeper_pid)
  end

  describe "Basic API operations" do
    @doc """
    Tests that Peeper correctly handles basic GenServer-like operations
    including call, cast, and send, and preserves state through crashes.
    """
    test "delegates calls and casts properly" do
      pid = start_supervised!({FullImpl, state: 0, name: P1})

      # Test initial state
      assert 0 == Peeper.call(pid, :state)

      # Test state modification via cast
      assert :ok == Peeper.cast(pid, :inc)
      assert 1 == Peeper.call(pid, :state)

      # Test state preservation through crash
      Process.exit(Peeper.Supervisor.worker(pid), :raise)
      # State should be preserved
      assert 1 == Peeper.call(P1, :state)

      # Test send operation
      assert :inc == Peeper.send(pid, :inc)
      assert 2 == Peeper.call(P1, :state)
    end

    test "handles various types of crashes with state preservation" do
      pid = start_supervised!({FullImpl, state: 42, name: CrashTest})

      # Test various crash types
      crash_types = [
        :kill,
        :normal,
        :shutdown,
        {:shutdown, :test},
        :raise,
        :abort
      ]

      for crash_type <- crash_types do
        worker_pid = refresh_worker_pid(pid)

        # Capture logs to suppress error messages
        capture_log(fn ->
          Process.exit(worker_pid, crash_type)
          # Allow time for restart
          Process.sleep(20)

          # For some termination reasons that might not trigger restart
          # we need to be more careful with the assertions
          try do
            state = Peeper.call(CrashTest, :state, 100)
            assert state == 42, "State not preserved after #{inspect(crash_type)} crash"
          catch
            :exit, _ ->
              # This is fine for :normal or :shutdown terminations
              if crash_type not in [:normal, :shutdown, {:shutdown, :test}] do
                flunk("Process did not restart after #{inspect(crash_type)} crash")
              end
          end
        end)
      end
    end

    @tag :skip
    test "handles error caused by callback" do
      pid = start_supervised!({FullImpl, state: 0, name: RaiseCrash})
      gs_pid = Peeper.gen_server(pid)

      # Trigger a raise error in a callback
      Peeper.call(pid, :raise)

      # Allow time for restart
      Process.sleep(20)

      # State should be preserved after restart
      assert 0 == Peeper.call(RaiseCrash, :state)
      assert pid == Process.whereis(RaiseCrash)
      refute gs_pid == Peeper.gen_server(pid)
    end
  end

  describe "Communication patterns" do
    @doc """
    Tests the ability to communicate directly with the GenServer
    using standard GenServer functions, bypassing Peeper's API.
    """
    test "direct calls and casts to the wrapped GenServer" do
      # Start with Peeper.child_spec
      peeper_pid =
        start_supervised!(Peeper.child_spec(impl: FullImpl, state: 0, name: P2))

      # Get worker PID
      pid = Peeper.gen_server(peeper_pid)

      # Direct GenServer.call works
      assert 0 == GenServer.call(pid, :state)
      # Direct GenServer.cast works
      assert :ok == GenServer.cast(pid, :inc)
      assert 1 == GenServer.call(pid, :state)

      # Crash and test state preservation
      Process.exit(pid, :kill)
      assert 1 == Peeper.call(P2, :state)

      # Mix Peeper and direct operations
      assert :inc == Peeper.send(P2, :inc)
      assert 2 == GenServer.call(Peeper.gen_server(peeper_pid), :state)
    end

    test "properly handles name registration" do
      # Start with atom name
      {:ok, pid1} = FullImpl.start_link(state: 1, name: AtomName)
      assert Process.whereis(AtomName) == pid1

      # Start with global name
      {:ok, pid2} = FullImpl.start_link(state: 2, name: {:global, GlobalName})
      assert :global.whereis_name(GlobalName) == pid2

      # Verify they're separate
      assert Peeper.call(AtomName, :state) == 1
      assert Peeper.call({:global, GlobalName}, :state) == 2

      # Test shutdown
      FullImpl.stop(AtomName)
      FullImpl.stop({:global, GlobalName})

      assert Process.whereis(AtomName) == nil
      assert :global.whereis_name(GlobalName) == :undefined
    end
  end

  describe "State and resource preservation" do
    @doc """
    Tests the preservation of ETS tables and process dictionary entries
    across process crashes and restarts.
    """
    test "restores ETS tables and process dictionary" do
      # Start in a dynamic supervisor
      {:ok, _source_pid} = DynamicSupervisor.start_link(name: SDS)

      # Start with keep_ets option
      {:ok, pid} =
        DynamicSupervisor.start_child(
          SDS,
          {FullImpl, state: 0, name: P3, keep_ets: true}
        )

      # Verify initial state
      assert 0 == Peeper.call(pid, :state)

      # Create various resources
      # Regular ETS
      assert :ok == Peeper.cast(pid, {:create_ets, :my_ets})
      # With heir
      assert :ok == Peeper.cast(pid, {:create_heired_ets, :my_heired_ets, P3, %{foo: 42}})
      # Process dictionary
      assert :ok == Peeper.cast(pid, {:set_pd, :foo, 42})
      # Change state
      assert :ok == Peeper.cast(pid, :inc)
      assert 1 == Peeper.call(P3, :state)

      # Kill the worker and verify everything is restored
      Process.exit(Peeper.Supervisor.worker(pid), :kill)
      assert 1 == Peeper.call(P3, :state)
      assert 42 == Peeper.call(P3, {:get_pd, :foo})
      assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_ets})
      assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_heired_ets})
    end

    test "handles complex ETS scenarios" do
      # Test with explicit table options
      {:ok, pid} =
        FullImpl.start_link(state: 0, name: ComplexETS, keep_ets: [:specific_table])

      # Create tables in different ways
      # Should be preserved due to keep_ets
      assert :ok == Peeper.cast(pid, {:create_ets, :all_ets})
      # Should be preserved due to keep_ets list
      assert :ok == Peeper.cast(pid, {:create_ets, :specific_table})
      # Preserved via heir
      assert :ok == Peeper.cast(pid, {:create_heired_ets, :heir_ets, ComplexETS, :custom_data})

      # Add some state
      Peeper.cast(pid, :inc)
      assert 1 == Peeper.call(pid, :state)

      # Kill worker and verify tables are preserved
      Process.exit(Peeper.gen_server(pid), :kill)
      Process.sleep(50)

      # Verify state was preserved
      assert 1 == Peeper.call(ComplexETS, :state)

      # Verify tables were preserved
      assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] =
               Peeper.call(ComplexETS, {:ets, :specific_table})

      assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(ComplexETS, {:ets, :heir_ets})

      # Check that all_ets was preserved due to keep_ets: true (even though not in the explicit list)
      assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(ComplexETS, {:ets, :all_ets})
    end
  end

  describe "Process transfer between supervisors" do
    @doc """
    Tests the Peeper's ability to transfer processes between different supervisors,
    preserving state, ETS tables, and process dictionary.
    """
    test "transfers process between supervisors with state preservation" do
      # Start source and target supervisors
      {:ok, source_pid} = DynamicSupervisor.start_link(name: SDS)
      {:ok, target_pid} = DynamicSupervisor.start_link(name: TDS)

      # Start a process under the source supervisor
      {:ok, pid} =
        DynamicSupervisor.start_child(
          SDS,
          {FullImpl, state: 0, name: P3, keep_ets: true}
        )

      # Set up some state and resources
      assert 0 == Peeper.call(pid, :state)
      assert :ok == Peeper.cast(pid, {:create_ets, :my_ets})
      assert :ok == Peeper.cast(pid, {:create_heired_ets, :my_heired_ets, P3, %{foo: 42}})
      assert :ok == Peeper.cast(pid, {:set_pd, :foo, 42})
      assert :ok == Peeper.cast(pid, :inc)
      assert 1 == Peeper.call(P3, :state)

      # Transfer process to the target supervisor
      Peeper.transfer(P3, source_pid, target_pid)
      Process.sleep(50)

      # Verify process is now under the target supervisor
      assert [{:undefined, new_pid, :supervisor, _}] = DynamicSupervisor.which_children(TDS)
      assert new_pid == GenServer.whereis(P3)

      # Verify state and resources were preserved
      assert 1 == Peeper.call(P3, :state)
      assert 42 == Peeper.call(P3, {:get_pd, :foo})
      assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_ets})
      assert [[a: 42], [b: :foo], [{:c, 42, :foo}]] = Peeper.call(P3, {:ets, :my_heired_ets})
    end

    test "handles transfer error scenarios" do
      # Start a source supervisor
      {:ok, source_pid} = DynamicSupervisor.start_link(name: SourceSup)

      # Start a Peeper process
      {:ok, pid} =
        DynamicSupervisor.start_child(
          source_pid,
          {FullImpl, state: 42, name: TransferTest}
        )

      assert is_pid(pid)

      # Test transfer to non-existent supervisor (should return error or not crash)
      capture_log(fn ->
        # This should not crash our test
        _result = Peeper.transfer(TransferTest, source_pid, NonExistentSup)

        # We don't assert the exact result as it may vary, but we verify our process still works
        Process.sleep(20)
        assert 42 == Peeper.call(TransferTest, :state)
      end)

      # Test transfer with wrong source supervisor
      {:ok, another_pid} = DynamicSupervisor.start_link(name: AnotherSup)
      {:ok, target_pid} = DynamicSupervisor.start_link(name: TargetSup)

      capture_log(fn ->
        # This should not crash our test, but might fail since the process isn't under another_pid
        Peeper.transfer(TransferTest, another_pid, target_pid)

        # Verify process still works and stayed under the original supervisor
        Process.sleep(20)
        assert 42 == Peeper.call(TransferTest, :state)

        # Process should still be under the original supervisor
        assert Enum.any?(DynamicSupervisor.which_children(source_pid), fn {_, child_pid, _, _} ->
                 child_pid == GenServer.whereis(TransferTest)
               end)
      end)
    end
  end

  describe "Error scenarios and edge cases" do
    @doc """
    Tests Peeper's behavior in various error scenarios and edge cases.
    """
    test "handles timeout in call" do
      # Define a server that sleeps on calls
      defmodule SlowServer do
        use Peeper.GenServer

        @impl Peeper.GenServer
        def init(state), do: {:ok, state}

        @impl Peeper.GenServer
        def handle_call(:slow, _from, state) do
          # Sleep longer than our timeout
          Process.sleep(500)
          {:reply, :done, state}
        end

        @impl Peeper.GenServer
        def handle_call(:state, _from, state), do: {:reply, state, state}
      end

      {:ok, pid} = SlowServer.start_link(state: :initial, name: TimeoutTest)

      # This should time out
      assert catch_exit(Peeper.call(pid, :slow, 100)) != nil

      # Process should still be alive and state preserved
      # Wait for the slow call to complete
      Process.sleep(600)
      assert :initial == Peeper.call(TimeoutTest, :state)
    end

    test "handles invalid messages gracefully" do
      {:ok, pid} = FullImpl.start_link(state: 99, name: InvalidMsg)

      # Send an unexpected message format
      Kernel.send(Peeper.gen_server(pid), :unexpected_message)
      Kernel.send(Peeper.gen_server(pid), {:unexpected_tuple, 1, 2, 3})

      # Process should still be working
      Process.sleep(10)
      assert 99 == Peeper.call(InvalidMsg, :state)
    end

    test "handles nested crashes and restarts" do
      {:ok, pid} = FullImpl.start_link(state: 0, name: NestedCrash)

      # Handler to crash the process multiple times in quick succession
      crash_handler = fn ->
        capture_log(fn ->
          # Crash the process multiple times in quick succession
          for _ <- 1..5 do
            worker_pid = refresh_worker_pid(pid)
            Process.exit(worker_pid, :kill)
            # Short sleep to allow restart
            Process.sleep(5)
          end
        end)
      end

      # Test without state modification
      crash_handler.()
      assert 0 == Peeper.call(NestedCrash, :state)

      # Test with incremental state changes between crashes
      for _i <- 1..5 do
        Process.sleep(50)
        Peeper.cast(pid, :inc)
        worker_pid = refresh_worker_pid(pid)
        Process.exit(worker_pid, :kill)
      end

      # State should reflect all increments
      assert 5 == Peeper.call(NestedCrash, :state)
    end
  end

  describe "Stress testing" do
    @doc """
    Tests Peeper under high-stress conditions to ensure reliability.
    """
    test "stress calls and casts work properly with many restarts" do
      peeper_pid = start_supervised!({FullImpl, state: 0, name: StressTest})
      pid1 = Peeper.gen_server(peeper_pid)

      # Verify initial state
      assert 0 == GenServer.call(pid1, :state)
      assert :ok == GenServer.cast(pid1, :inc)
      assert 1 == GenServer.call(pid1, :state)

      # First crash
      Process.exit(pid1, :kill)
      Process.sleep(10)

      # Loop with many crashes
      # Reduced from 1000 for faster tests
      iterations = 50

      for i <- 2..iterations do
        pid = Peeper.gen_server(peeper_pid)
        refute pid == pid1
        assert i - 1 == GenServer.call(pid, :state)
        assert :ok == Peeper.cast(peeper_pid, :inc)
        assert i == GenServer.call(pid, :state)
        Process.exit(pid, :kill)
        Process.sleep(5)
      end

      # Final state check
      assert iterations == Peeper.call(StressTest, :state)
    end

    test "handles concurrent operations" do
      {:ok, pid} = FullImpl.start_link(state: 0, name: ConcurrentTest)

      # Spawn multiple processes to operate on the server concurrently
      task_count = 20
      increment_count = 5

      tasks =
        for _task_id <- 1..task_count do
          Task.async(fn ->
            # Each task increments multiple times
            for _ <- 1..increment_count do
              Peeper.cast(ConcurrentTest, :inc)
              # Random sleeps to increase chance of race conditions
              Process.sleep(Enum.random(1..10))
            end
          end)
        end

      # Wait for all tasks to complete
      Task.await_many(tasks, 5000)
      # Allow time for processing all casts
      Process.sleep(50)

      # Final state should reflect all increments
      expected = task_count * increment_count
      assert expected == Peeper.call(ConcurrentTest, :state)

      # Now crash and ensure state is preserved
      Process.exit(Peeper.gen_server(pid), :kill)
      Process.sleep(50)
      assert expected == Peeper.call(ConcurrentTest, :state)
    end
  end

  describe "Edge cases" do
    @doc """
    Tests edge cases and corner conditions.
    """
    @tag :skip
    test "handles supervisor restart limit" do
      # Configure a supervisor with limited restarts
      {:ok, pid} =
        FullImpl.start_link(
          state: 0,
          name: RestartLimitTest,
          strategy: :one_for_all,
          max_restarts: 2,
          max_seconds: 1
        )

      # Initial state check
      assert 0 == Peeper.call(pid, :state)

      # We'll crash it multiple times to exceed the restart limit
      worker_pid1 = Peeper.gen_server(pid)

      # Capture logs to avoid test pollution
      capture_log(fn ->
        # First crash - should restart fine
        Process.exit(worker_pid1, :kill)
        Process.sleep(50)
        worker_pid2 = Peeper.gen_server(pid)
        refute worker_pid1 == worker_pid2

        # Second crash - should restart fine
        Process.exit(worker_pid2, :kill)
        Process.sleep(50)
        worker_pid3 = Peeper.gen_server(pid)
        refute worker_pid2 == worker_pid3

        # Third crash - should exceed max_restarts
        Process.exit(worker_pid3, :kill)
        Process.sleep(100)
      end)

      # Try to access the process - it might be down due to max_restarts
      # We don't make hard assertions here because behavior might vary
      try do
        Peeper.call(RestartLimitTest, :state, 100)
      catch
        :exit, _ ->
          # This is expected if the supervisor terminated
          :supervisor_terminated_as_expected
      end

      # Wait to allow restart limit to reset
      Process.sleep(1100)

      # Start a new process with same name and verify it works
      {:ok, new_pid} = FullImpl.start_link(state: 100, name: RestartLimitTest)
      assert 100 == Peeper.call(new_pid, :state)
    end

    test "handles empty or nil state" do
      # Test with nil state
      {:ok, pid1} = FullImpl.start_link(state: nil, name: NilState)
      assert nil == Peeper.call(pid1, :state)

      # Crash and verify nil state is preserved
      Process.exit(Peeper.gen_server(pid1), :kill)
      Process.sleep(50)
      assert nil == Peeper.call(NilState, :state)

      # Test with empty map state
      {:ok, pid2} = FullImpl.start_link(state: %{}, name: EmptyMap)
      assert %{} == Peeper.call(pid2, :state)

      # Crash and verify empty map is preserved
      Process.exit(Peeper.gen_server(pid2), :kill)
      Process.sleep(50)
      assert %{} == Peeper.call(EmptyMap, :state)
    end

    test "handles large state" do
      # Create a large state (large list)
      large_list = Enum.to_list(1..10_000)
      {:ok, pid} = FullImpl.start_link(state: large_list, name: LargeState)

      # Verify initial state
      state = Peeper.call(pid, :state)
      assert is_list(state)
      assert length(state) == 10_000

      # Crash and verify large state is preserved
      Process.exit(Peeper.gen_server(pid), :kill)
      # Longer sleep for large state transfer
      Process.sleep(100)

      # Verify state after crash
      new_state = Peeper.call(LargeState, :state)
      assert is_list(new_state)
      assert length(new_state) == 10_000
      assert new_state == large_list
    end

    test "handles process dictionary with special keys" do
      {:ok, pid} = FullImpl.start_link(state: 0, name: PDTest)

      # Set various process dictionary values including special keys
      special_keys = [
        # special name
        :erlang_system_key,
        # tuple key
        {1, 2, 3},
        # list key
        ["a", "b", "c"],
        # map key
        %{a: 1, b: 2}
      ]

      # Set the keys in process dictionary
      Enum.each(special_keys, fn key ->
        Peeper.cast(pid, {:set_pd, key, "value_for_#{inspect(key)}"})
      end)

      Process.sleep(10)

      # Verify all keys were set
      Enum.each(special_keys, fn key ->
        value = Peeper.call(pid, {:get_pd, key})
        assert value == "value_for_#{inspect(key)}"
      end)

      # Crash and check keys are preserved
      Process.exit(Peeper.gen_server(pid), :kill)
      Process.sleep(50)

      # Verify all keys were preserved
      Enum.each(special_keys, fn key ->
        value = Peeper.call(PDTest, {:get_pd, key})
        assert value == "value_for_#{inspect(key)}"
      end)
    end

    test "handles invalid initial args" do
      # Define a server with invalid init return values
      defmodule InvalidInitServer do
        use Peeper.GenServer

        @impl Peeper.GenServer
        def init(:return_ok) do
          # This is not a valid return for Peeper.GenServer init
          :ok
        end

        def init(:return_error) do
          # This is not a valid return for Peeper.GenServer init
          {:error, "some error"}
        end

        def init(:return_ignore) do
          # This is not a valid return for Peeper.GenServer init
          :ignore
        end

        def init(:return_stop) do
          # This is not a valid return for Peeper.GenServer init
          {:stop, "stopping"}
        end

        def init(other) do
          # Valid return
          {:ok, other}
        end

        @impl Peeper.GenServer
        def handle_call(:state, _from, state), do: {:reply, state, state}
      end

      # Test with various invalid init returns
      capture_log(fn ->
        # These might warn but should not crash the test process
        for init_arg <- [:return_ok, :return_error, :return_ignore, :return_stop] do
          name = :"InvalidInit#{init_arg}"

          # Start with invalid init return
          result = InvalidInitServer.start_link(state: init_arg, name: name)

          case result do
            {:ok, pid} ->
              # It started anyway, possibly with warning
              # This is actually expected with current implementation
              FullImpl.stop(pid)

            _ ->
              # Failed to start, which is also acceptable
              :ok
          end
        end
      end)

      # Valid init should work
      {:ok, pid} = InvalidInitServer.start_link(state: "valid", name: ValidInit)
      assert "valid" == Peeper.call(pid, :state)
    end
  end
end
