defmodule FlockitNotifyTest do
  # Synchronous: these tests change application env and count the VM-wide
  # registrations.
  use ExUnit.Case, async: false

  alias Flockit.NIF

  @moduletag :tmp_dir

  # Holds a lock in another OS process. Unlocks explicitly after `hold`
  # seconds if `linger` is given, keeping the file open for `linger` more.
  @perl_holder """
  use Fcntl qw(:flock);
  my ($path, $hold, $linger) = @ARGV;
  open(my $f, ">>", $path) or die "open: $!";
  flock($f, LOCK_EX) or die "flock: $!";
  $| = 1;
  print "locked\\n";
  select(undef, undef, undef, $hold);
  if (defined $linger) {
    flock($f, LOCK_UN) or die "unlock: $!";
    print "unlocked\\n";
    select(undef, undef, undef, $linger);
  }
  """

  setup do
    previous = Application.get_env(:flockit, :max_poll_interval)
    on_exit(fn -> Application.put_env(:flockit, :max_poll_interval, previous) end)
    eventually(fn -> NIF.watch_count() == 0 end)
    :ok
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  # So slow that any prompt wake-up must have come from a notification.
  defp disable_fallback, do: Application.put_env(:flockit, :max_poll_interval, 60_000)

  defp holder(path) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lock} = Flockit.lock(path)
        send(parent, {:held, self()})
        receive do: (:unlock -> Flockit.unlock(lock))
        receive do: (:stop -> :ok)
      end)

    assert_receive {:held, ^pid}, 1_000
    pid
  end

  defp timed_lock(path, opts \\ []) do
    Task.async(fn ->
      result = Flockit.lock(path, opts)
      {result, System.monotonic_time(:millisecond)}
    end)
  end

  defp perl_holder(path, args) do
    perl = System.find_executable("perl") || flunk("perl is needed for cross-process tests")

    port =
      Port.open({:spawn_executable, perl}, [:binary, args: ["-e", @perl_holder, path | args]])

    assert_receive {^port, {:data, "locked\n"}}, 5_000
    port
  end

  describe "notifications" do
    test "wake a waiter as soon as a holder in this VM unlocks", %{tmp_dir: dir} do
      disable_fallback()
      path = Path.join(dir, "lock")
      pid = holder(path)
      task = timed_lock(path)

      # Between fallback retries at 630ms and 1270ms.
      Process.sleep(700)
      unlocked_at = System.monotonic_time(:millisecond)
      send(pid, :unlock)

      assert {{:ok, lock}, locked_at} = Task.await(task)
      assert locked_at - unlocked_at < 200
      Flockit.unlock(lock)
    end

    test "wake a waiter when a holder in another OS process exits", %{tmp_dir: dir} do
      disable_fallback()
      path = Path.join(dir, "lock")
      _port = perl_holder(path, ["1.5"])
      start = System.monotonic_time(:millisecond)

      # The holder exits 1.5s after locking. Fallback retries back off to
      # 1270ms and then 2550ms after the first attempt, so only a
      # notification gets the lock soon after 1.5s.
      assert {{:ok, lock}, locked_at} = Task.await(timed_lock(path), 5_000)
      assert locked_at - start < 2_100
      Flockit.unlock(lock)
    end

    test "fallback retries catch an unlock that keeps the file open", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      port = perl_holder(path, ["0.3", "5"])

      assert {{:ok, lock}, _} = Task.await(timed_lock(path), 3_000)
      assert_receive {^port, {:data, "unlocked\n"}}
      Flockit.unlock(lock)
      Port.close(port)
    end

    @tag :capture_log
    test "resume after the notifier restarts", %{tmp_dir: dir} do
      disable_fallback()
      old = Process.whereis(Flockit.Notifier)
      Process.exit(old, :kill)
      eventually(fn -> Process.whereis(Flockit.Notifier) not in [nil, old] end)

      path = Path.join(dir, "lock")
      pid = holder(path)
      task = timed_lock(path)
      # Between fallback retries at 630ms and 1270ms.
      Process.sleep(700)
      unlocked_at = System.monotonic_time(:millisecond)
      send(pid, :unlock)

      assert {{:ok, lock}, locked_at} = Task.await(task)
      assert locked_at - unlocked_at < 200
      Flockit.unlock(lock)
    end
  end

  describe "registrations" do
    test "are dropped when a wait times out", %{tmp_dir: dir} do
      paths = for i <- 1..20, do: Path.join(dir, "lock#{i}")
      pids = Enum.map(paths, &holder/1)

      for path <- paths, do: assert(Flockit.lock(path, timeout: 20) == {:error, :timeout})
      assert NIF.watch_count() == 0

      Enum.each(pids, &send(&1, :stop))
    end

    test "are dropped when the waiting process is killed", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      pid = holder(path)
      waiter = spawn(fn -> Flockit.lock(path) end)

      eventually(fn -> NIF.watch_count() == 1 end)
      Process.exit(waiter, :kill)
      eventually(fn -> NIF.watch_count() == 0 end)
      send(pid, :stop)
    end

    test "are dropped once the lock is acquired", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      pid = holder(path)
      task = timed_lock(path)

      eventually(fn -> NIF.watch_count() == 1 end)
      send(pid, :unlock)
      assert {{:ok, lock}, _} = Task.await(task)
      assert NIF.watch_count() == 0
      Flockit.unlock(lock)
    end
  end

  describe "load" do
    test "a storm of release events leaves each waiter at most one message", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      {:ok, shared} = Flockit.lock(path, mode: :shared)
      waiters = for _ <- 1..50, do: spawn(fn -> Flockit.lock(path) end)
      eventually(fn -> NIF.watch_count() == 50 end)
      Enum.each(waiters, &:erlang.suspend_process/1)

      # Every shared lock taken and dropped elsewhere raises a release event.
      Task.await(Task.async(fn -> Enum.each(1..2_000, fn _ -> churn_once(path) end) end), 30_000)

      # The notifier kept up, and suspended waiters were not flooded.
      assert %{notifier: _} = :sys.get_state(Flockit.Notifier, 5_000)
      queued = for w <- waiters, do: elem(Process.info(w, :message_queue_len), 1)
      assert Enum.all?(queued, &(&1 <= 1))
      assert Enum.sum(queued) > 0

      Enum.each(waiters, &:erlang.resume_process/1)
      Enum.each(waiters, &Process.exit(&1, :kill))
      Flockit.unlock(shared)
    end

    test "a storm across many files keeps the notifier responsive", %{tmp_dir: dir} do
      # Two descriptors per file: stay within a default 1024 limit while
      # needing several bounded drain calls per round of events.
      paths = for i <- 1..400, do: Path.join(dir, "lock#{i}")

      shared =
        Enum.map(paths, fn p ->
          {:ok, l} = Flockit.lock(p, mode: :shared)
          l
        end)

      waiters = for p <- paths, do: spawn(fn -> Flockit.lock(p) end)
      eventually(fn -> NIF.watch_count() == 400 end, 500)
      Enum.each(waiters, &:erlang.suspend_process/1)

      # Release events on every file, several times over.
      churn = Task.async(fn -> for _ <- 1..3, p <- paths, do: churn_once(p) end)

      # The notifier answers promptly while the storm is being delivered.
      for _ <- 1..20 do
        {micros, _} = :timer.tc(fn -> :sys.get_state(Flockit.Notifier, 5_000) end)
        assert micros < 500_000
        Process.sleep(10)
      end

      Task.await(churn, 60_000)

      eventually(
        fn ->
          Enum.all?(waiters, &(Process.info(&1, :message_queue_len) == {:message_queue_len, 1}))
        end,
        500
      )

      Enum.each(waiters, &:erlang.resume_process/1)
      Enum.each(waiters, &Process.exit(&1, :kill))
      Enum.each(shared, &Flockit.unlock/1)
      eventually(fn -> NIF.watch_count() == 0 end, 500)
    end

    test "a lock freed after the deadline is not returned late", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      pid = holder(path)
      task = Task.async(fn -> Flockit.lock(path, timeout: 200) end)
      eventually(fn -> NIF.watch_count() == 1 end)

      # Free the lock while the waiter cannot run, and only let it run again
      # after its deadline.
      :erlang.suspend_process(task.pid)
      send(pid, :unlock)
      Process.sleep(300)
      :erlang.resume_process(task.pid)

      assert Task.await(task) == {:error, :timeout}
      assert {:ok, lock} = Flockit.try_lock(path)
      Flockit.unlock(lock)
    end

    @tag :capture_log
    test "a notifier that cannot be set up keeps retrying" do
      parent = self()

      open = fn ->
        send(parent, :open_attempt)
        {:error, :emfile}
      end

      pid =
        start_supervised!(
          {Flockit.Notifier,
           name: :flockit_test_notifier, open: open, retry_interval: 20, attach: false}
        )

      assert_receive :open_attempt
      assert_receive :open_attempt, 1_000
      assert Process.alive?(pid)
    end

    test "a first attempt delayed past the deadline does not return the lock", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      fifo = Path.join(dir, "fifo")
      {_, 0} = System.cmd("mkfifo", [fifo])

      # Opening a FIFO for reading blocks until a writer appears, so these
      # occupy every dirty IO scheduler and the lock attempt queues behind them.
      blockers =
        for _ <- 1..:erlang.system_info(:dirty_io_schedulers),
            do: Task.async(fn -> File.open(fifo, [:read, :raw]) end)

      Process.sleep(100)
      task = Task.async(fn -> Flockit.lock(path, timeout: 50) end)
      Process.sleep(300)

      writer = Port.open({:spawn, "sh -c 'exec 3>#{fifo}; sleep 2'"}, [])
      assert Task.await(task) == {:error, :timeout}
      Enum.each(blockers, &Task.await/1)
      assert {:ok, lock} = Flockit.try_lock(path)
      Flockit.unlock(lock)
      Port.close(writer)
    end
  end

  describe "automatic release" do
    setup do
      # A failed assertion must not leave the notifier suspended or stopped
      # for later tests.
      on_exit(fn ->
        start_notifier()
        :sys.resume(Flockit.Notifier)
      end)
    end

    test "hands the descriptor to the notifier when the owner exits", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      parent = self()

      owner =
        spawn(fn ->
          {:ok, _lock} = Flockit.lock(path)
          send(parent, :locked)
          receive do: (:stop -> :ok)
        end)

      assert_receive :locked
      :sys.suspend(Flockit.Notifier)
      Process.exit(owner, :kill)

      # Nothing is closed in the exit callback itself...
      Process.sleep(100)
      assert Flockit.try_lock(path) == {:error, :eagain}

      # ...but promptly once the notifier runs.
      :sys.resume(Flockit.Notifier)
      eventually(fn -> match?({:ok, _}, Flockit.try_lock(path)) end)
    end

    test "queues closes while the notifier is down and makes them when it returns",
         %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      pid = owner(path)
      stop_notifier()
      kill_owner(pid)

      # Not closed in the exit callback, even with no notifier to take it...
      Process.sleep(100)
      assert held_elsewhere?(path)

      # ...and closed as soon as a notifier attaches.
      start_notifier()
      eventually(fn -> not held_elsewhere?(path) end)
    end

    test "without a notifier, the library's own calls make queued closes", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      pid = owner(path)
      stop_notifier()
      kill_owner(pid)
      Process.sleep(100)
      assert held_elsewhere?(path)

      # Any dirty call, here on an unrelated file, takes a share of the queue.
      assert {:ok, other} = Flockit.try_lock(Path.join(dir, "other"))
      refute held_elsewhere?(path)
      Flockit.unlock(other)
      start_notifier()
    end

    test "closes queued descriptors oldest first", %{tmp_dir: dir} do
      :sys.suspend(Flockit.Notifier)
      first = Path.join(dir, "first")
      kill_owner(owner(first))
      Process.sleep(50)

      # More than one batch of newer closes behind it.
      later = for i <- 1..100, do: owner(Path.join(dir, "later#{i}"))
      Enum.each(later, &kill_owner/1)
      Process.sleep(50)

      assert NIF.close_pending() == :more
      assert {:ok, lock} = Flockit.try_lock(first)
      Flockit.unlock(lock)
    end

    test "hands the descriptor to the notifier when the handle is collected", %{tmp_dir: dir} do
      path = Path.join(dir, "lock")
      :sys.suspend(Flockit.Notifier)

      parent = self()

      pid =
        spawn(fn ->
          {:ok, _} = Flockit.try_lock(path)
          :erlang.garbage_collect()
          send(parent, :collected)
          receive do: (:stop -> :ok)
        end)

      assert_receive :collected
      Process.sleep(100)
      assert Flockit.try_lock(path) == {:error, :eagain}

      :sys.resume(Flockit.Notifier)
      eventually(fn -> match?({:ok, _}, Flockit.try_lock(path)) end)
      send(pid, :stop)
    end
  end

  defp stop_notifier, do: :ok = Supervisor.terminate_child(Flockit.Supervisor, Flockit.Notifier)

  defp start_notifier do
    case Supervisor.restart_child(Flockit.Supervisor, Flockit.Notifier) do
      {:ok, _} -> :ok
      {:error, :running} -> :ok
    end
  end

  # Whether another OS process finds path locked, checked without calling
  # into this library (whose calls can themselves make queued closes).
  defp held_elsewhere?(path) do
    script = ~S"""
    use Fcntl qw(:flock);
    open(my $f, "<", $ARGV[0]) or die "open: $!";
    exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1);
    """

    {_, status} = System.cmd(System.find_executable("perl"), ["-e", script, path])
    status == 1
  end

  # A process holding a lock on path until killed.
  defp owner(path) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _lock} = Flockit.lock(path)
        send(parent, {:owned, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owned, ^pid}, 1_000
    pid
  end

  defp kill_owner(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp churn_once(path) do
    {:ok, lock} = Flockit.try_lock(path, mode: :shared)
    Flockit.unlock(lock)
  end
end
