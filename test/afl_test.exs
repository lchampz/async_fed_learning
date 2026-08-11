defmodule AFL.Test do
  use ExUnit.Case, async: false
  require Logger

  # Reset the supervised Aggregator to a clean state before each test.
  # We do NOT stop it — that would trigger the supervisor with unknown timing.
  #
  # Also clears :edge_buffer unconditionally before every test. Under
  # posse invertida (AFL.BufferKeeper owns this table permanently — see
  # its moduledoc), the table is never destroyed between tests, so a
  # previous test's on_exit cleanup racing with process teardown could
  # otherwise leak entries into the next test (order-dependent flakiness).
  # Clearing it here, independently of any single test's own cleanup,
  # makes every test's starting state deterministic regardless of order.
  setup do
    AFL.Aggregator.reset(MockML.initial_weights())
    :ets.delete_all_objects(:edge_buffer)
    :ok
  end

  defp stop_edge_node do
    case Process.whereis(AFL.EdgeNode) do
      nil ->
        :ok

      pid ->
        try do
          ref = Process.monitor(pid)
          :gen_statem.stop(pid)
          receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (1000 -> :ok)
        catch
          # Process may have already exited between whereis/stop
          :exit, _ -> :ok
        end
    end
  end

  # Kill the aggregator and wait for the :DOWN signal to arrive.
  # The supervisor will restart it, but the EdgeNode won't poll for 5 s,
  # giving us a safe window to test the :disconnected state.
  defp kill_aggregator do
    pid = Process.whereis(AFL.Aggregator)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> pid), after: (500 -> nil)
  end

  defp assert_tensors_close(actual, expected, tolerance) do
    max_diff =
      Nx.abs(Nx.subtract(actual, expected))
      |> Nx.reduce_max()
      |> Nx.to_number()

    assert max_diff < tolerance,
           "Tensors differ by #{max_diff}, expected < #{tolerance}"
  end

  # -------------------------------------------------------------------
  # AFL.Aggregator — math correctness
  # -------------------------------------------------------------------

  describe "AFL.Aggregator" do
    test "starts with zero weights" do
      assert_tensors_close(AFL.Aggregator.get_model(), MockML.initial_weights(), 1.0e-6)
    end

    test "increments version and updates_count on each update" do
      AFL.Aggregator.update(MockML.train(), 100)
      state = AFL.Aggregator.get_state()
      assert state.updates_count == 1
      assert state.version == 1
    end

    test "FedAvg: equal sample sizes produce the arithmetic mean" do
      AFL.Aggregator.update(Nx.broadcast(2.0, {10}), 100)
      AFL.Aggregator.update(Nx.broadcast(4.0, {10}), 100)
      assert_tensors_close(AFL.Aggregator.get_model(), Nx.broadcast(3.0, {10}), 1.0e-5)
    end

    test "FedAvg: larger sample size weighs more" do
      # Expected: (100×1.0 + 300×3.0) / 400 = 2.5
      AFL.Aggregator.update(Nx.broadcast(1.0, {10}), 100)
      AFL.Aggregator.update(Nx.broadcast(3.0, {10}), 300)
      assert_tensors_close(AFL.Aggregator.get_model(), Nx.broadcast(2.5, {10}), 1.0e-5)
    end

    test "stale updates are penalized — large staleness gap reduces contribution" do
      # Establish model≈1.0 at version 5
      for _ <- 1..5, do: AFL.Aggregator.update(Nx.broadcast(1.0, {10}), 1000)
      assert AFL.Aggregator.get_state().version == 5

      # Stale update: edge_version=0, current=5 → gap=5, staleness_factor=1/6≈0.167
      # Without penalty the update would push model strongly toward 100.0;
      # with penalty, effective_n_k ≈ 167, so the pull is much weaker.
      AFL.Aggregator.update(Nx.broadcast(100.0, {10}), 1000, 0)

      avg_val = AFL.Aggregator.get_model() |> Nx.mean() |> Nx.to_number()
      assert avg_val < 20.0,
             "Staleness penalty should cap impact far below 100.0 (got #{avg_val})"
    end

    test "get_version/0 is consistent with internal state" do
      AFL.Aggregator.update(MockML.train(), 50)
      AFL.Aggregator.update(MockML.train(), 50)
      assert AFL.Aggregator.get_version() == AFL.Aggregator.get_state().version
    end
  end

  # -------------------------------------------------------------------
  # AFL.EdgeNode — state machine behaviour
  # -------------------------------------------------------------------

  describe "AFL.EdgeNode" do
    setup do
      on_exit(&stop_edge_node/0)
    end

    test "starts :connected when Aggregator is up" do
      {:ok, _} = AFL.EdgeNode.start_link(:node_1)
      {state, _data} = :sys.get_state(AFL.EdgeNode)
      assert state == :connected
    end

    test "transitions to :disconnected when Aggregator goes down" do
      {:ok, en_pid} = AFL.EdgeNode.start_link(:node_2)
      {state, _} = :sys.get_state(en_pid)
      assert state == :connected

      kill_aggregator()
      # Let the :DOWN message propagate through the EdgeNode mailbox
      Process.sleep(200)

      {state, _} = :sys.get_state(en_pid)
      assert state == :disconnected
    end

    test "buffers updates in ETS while disconnected" do
      {:ok, en_pid} = AFL.EdgeNode.start_link(:node_3)
      kill_aggregator()
      Process.sleep(200)

      {state, _} = :sys.get_state(en_pid)
      assert state == :disconnected

      :gen_statem.cast(en_pid, :train_and_send)
      :gen_statem.cast(en_pid, :train_and_send)
      :gen_statem.cast(en_pid, :train_and_send)
      # A :sys.get_state call drains the cast queue (FIFO mailbox ordering)
      :sys.get_state(en_pid)

      assert :ets.info(:edge_buffer, :size) == 3
    end

    test "ring buffer wraps around and caps at @max_buffer (5)" do
      {:ok, en_pid} = AFL.EdgeNode.start_link(:node_4)
      kill_aggregator()
      Process.sleep(200)

      {state, _} = :sys.get_state(en_pid)
      assert state == :disconnected

      # 7 writes into a buffer of size 5
      for _ <- 1..7 do
        :gen_statem.cast(en_pid, :train_and_send)
      end

      :sys.get_state(en_pid)

      assert :ets.info(:edge_buffer, :size) == 5,
             "Ring buffer should cap at 5 entries regardless of total writes"
    end
  end

  # -------------------------------------------------------------------
  # Chaos Engineering
  # -------------------------------------------------------------------

  describe "Chaos Engineering" do
    test "model is consistent under 20 concurrent async updates" do
      tasks =
        for i <- 1..20 do
          Task.async(fn -> AFL.Aggregator.update(Nx.broadcast(i * 1.0, {10}), 100) end)
        end

      Enum.each(tasks, &Task.await/1)

      state = AFL.Aggregator.get_state()
      assert state.updates_count == 20

      avg_val = AFL.Aggregator.get_model() |> Nx.mean() |> Nx.to_number()
      assert avg_val > 0.0
      assert avg_val < 21.0
    end

    test "stale-update stress: staleness penalty keeps model far from extreme inputs" do
      # Phase 1 — 10 fresh updates driving the model toward 1.0
      for _ <- 1..10, do: AFL.Aggregator.update(Nx.broadcast(1.0, {10}), 100)
      assert AFL.Aggregator.get_version() == 10

      # Phase 2 — 10 stale updates (edge_version=0) with extreme weight 999.0
      # Without penalty FedAvg would average to ≈500.0; with penalty, model ≈63
      for _ <- 1..10, do: AFL.Aggregator.update(Nx.broadcast(999.0, {10}), 100, 0)

      assert AFL.Aggregator.get_state().updates_count == 20

      avg_val = AFL.Aggregator.get_model() |> Nx.mean() |> Nx.to_number()

      # Penalty cuts effective_n_k by ~10×; model should be well below the
      # un-penalised expectation of ~500.0 and the conservative bound of 150.0
      assert avg_val < 150.0,
             "Staleness penalty must limit impact (no-penalty baseline ≈500, got #{avg_val})"
    end

    test "supervisor restarts Aggregator after :kill, preserving model state via AFL.ModelKeeper" do
      # Train past version 0 first — regression test for the gap found in
      # this work: without ModelKeeper, the restarted instance would reset
      # to the static initial_weights passed in the child_spec, silently
      # destroying all accumulated training progress on every crash.
      for _ <- 1..5, do: AFL.Aggregator.update_sync(Nx.broadcast(999.0, {10}), 100)
      assert AFL.Aggregator.get_version() == 5

      old_pid = Process.whereis(AFL.Aggregator)
      kill_aggregator()

      new_pid =
        Enum.reduce_while(1..40, nil, fn _, _ ->
          case Process.whereis(AFL.Aggregator) do
            pid when is_pid(pid) and pid != old_pid -> {:halt, pid}
            _ -> Process.sleep(50); {:cont, nil}
          end
        end)

      assert is_pid(new_pid), "Supervisor should restart AFL.Aggregator"
      assert Process.alive?(new_pid)
      # Restarted instance recovers the pre-crash state, not the static
      # initial_weights from the child_spec.
      assert AFL.Aggregator.get_version() == 5
      assert_tensors_close(AFL.Aggregator.get_model(), Nx.broadcast(999.0, {10}), 1.0e-5)
    end

    test "full round-trip: disconnect → buffer 3 updates → reconnect → flush" do
      on_exit(&stop_edge_node/0)
      {:ok, _} = AFL.EdgeNode.start_link(:chaos_node)

      # Apply 3 updates pre-disconnection so the Aggregator has a known version
      for _ <- 1..3, do: AFL.Aggregator.update(Nx.broadcast(1.0, {10}), 100)

      # Kill Aggregator → EdgeNode detects :DOWN → :disconnected
      kill_aggregator()
      Process.sleep(200)

      {state, _} = :sys.get_state(AFL.EdgeNode)
      assert state == :disconnected

      # Accumulate 3 offline training rounds into the buffer
      :gen_statem.cast(AFL.EdgeNode, :train_and_send)
      :gen_statem.cast(AFL.EdgeNode, :train_and_send)
      :gen_statem.cast(AFL.EdgeNode, :train_and_send)
      :sys.get_state(AFL.EdgeNode)
      assert :ets.info(:edge_buffer, :size) == 3

      # Supervisor restarts Aggregator; EdgeNode retry (5 s timeout) will flush
      new_pid =
        Enum.reduce_while(1..40, nil, fn _, _ ->
          case Process.whereis(AFL.Aggregator) do
            pid when is_pid(pid) -> {:halt, pid}
            _ -> Process.sleep(100); {:cont, nil}
          end
        end)

      assert is_pid(new_pid), "Supervisor must restart AFL.Aggregator"

      # Wait for EdgeNode's 5 s reconnect timeout + flush
      Process.sleep(6000)

      {final_state, _} = :sys.get_state(AFL.EdgeNode)
      assert final_state == :connected

      assert :ets.info(:edge_buffer, :size) == 0, "Buffer must be empty after flush"

      state = AFL.Aggregator.get_state()
      assert state.updates_count == 3, "3 buffered updates must have landed on the new Aggregator"
    end
  end
end
