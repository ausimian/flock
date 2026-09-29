defmodule FlockTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, path: Path.join(dir, "lock")}
  end

  # Runs `fun` in another process, which therefore opens its own lock file.
  defp elsewhere(fun), do: fun |> Task.async() |> Task.await()

  defp available?(path, mode \\ :exclusive) do
    elsewhere(fn -> match?({:ok, _}, Flock.try_lock(path, mode: mode)) end)
  end

  # Releases triggered by a process exit or GC happen asynchronously.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  # Starts a process holding a lock on `path` until told to :unlock or :stop.
  defp holder(path, opts \\ []) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lock} = Flock.lock(path, opts)
        send(parent, {:locked, self()})

        receive do
          :unlock -> send(parent, {:unlocked, self(), Flock.unlock(lock)})
          :stop -> :ok
        end
      end)

    assert_receive {:locked, ^pid}, 1_000
    pid
  end

  defp unlock_holder(pid) do
    send(pid, :unlock)
    assert_receive {:unlocked, ^pid, :ok}, 1_000
  end

  describe "exclusion" do
    test "an exclusive lock excludes all other lockers", %{path: path} do
      {:ok, lock} = Flock.lock(path)
      refute available?(path, :exclusive)
      refute available?(path, :shared)
      assert :ok = Flock.unlock(lock)
      assert available?(path, :exclusive)
    end

    test "shared locks coexist but exclude exclusive ones", %{path: path} do
      {:ok, lock} = Flock.lock(path, mode: :shared)
      assert available?(path, :shared)
      refute available?(path, :exclusive)
      Flock.unlock(lock)
    end

    test "try_lock/2 reports a conflict as :eagain", %{path: path} do
      {:ok, lock} = Flock.lock(path)
      assert elsewhere(fn -> Flock.try_lock(path) end) == {:error, :eagain}
      Flock.unlock(lock)
    end

    test "each call is a separate lock, even in the same process", %{path: path} do
      {:ok, lock} = Flock.try_lock(path)
      assert Flock.try_lock(path) == {:error, :eagain}
      assert Flock.lock(path, timeout: 0) == {:error, :timeout}
      Flock.unlock(lock)
    end

    test "creates the lock file", %{path: path} do
      refute File.exists?(path)
      {:ok, lock} = Flock.try_lock(path, mode: :shared)
      assert File.exists?(path)
      Flock.unlock(lock)
    end

    test "accepts chardata paths", %{path: path} do
      {:ok, lock} = Flock.try_lock([Path.dirname(path), ?/, String.to_charlist("lock")])
      refute available?(path)
      Flock.unlock(lock)
    end

    test "handles paths longer than 256 bytes", %{tmp_dir: dir} do
      deep = Path.join([dir | List.duplicate(String.duplicate("d", 60), 5)])
      File.mkdir_p!(deep)
      path = Path.join(deep, "lock")
      assert byte_size(path) > 300

      {:ok, lock} = Flock.try_lock(path)
      refute available?(path)
      Flock.unlock(lock)
    end
  end

  describe "release" do
    test "unlock/1 is idempotent", %{path: path} do
      {:ok, lock} = Flock.lock(path)
      assert :ok = Flock.unlock(lock)
      assert :ok = Flock.unlock(lock)
      assert available?(path)
    end

    test "unlock/1 works from another process", %{path: path} do
      {:ok, lock} = Flock.lock(path)
      assert elsewhere(fn -> Flock.unlock(lock) end) == :ok
      assert available?(path)
    end

    test "unlock/1 rejects anything but a lock" do
      assert_raise ArgumentError, fn -> Flock.unlock(make_ref()) end
    end

    test "a lock is released when its owner is killed", %{path: path} do
      pid = holder(path)
      refute available?(path)
      Process.exit(pid, :kill)
      eventually(fn -> available?(path) end)
    end

    test "a lock is released when its owner exits normally", %{path: path} do
      pid = holder(path)
      send(pid, :stop)
      eventually(fn -> available?(path) end)
    end

    test "a lock is released when its handle is garbage collected", %{path: path} do
      parent = self()

      pid =
        spawn(fn ->
          {:ok, _} = Flock.try_lock(path)
          :erlang.garbage_collect()
          send(parent, :collected)
          receive do: (:stop -> :ok)
        end)

      assert_receive :collected
      eventually(fn -> available?(path) end)
      assert Process.alive?(pid)
      send(pid, :stop)
    end
  end

  describe "waiting" do
    test "lock/2 waits until the lock is free", %{path: path} do
      pid = holder(path)
      task = Task.async(fn -> Flock.lock(path) end)
      assert Task.yield(task, 100) == nil

      unlock_holder(pid)
      assert {:ok, lock} = Task.await(task)
      assert Flock.unlock(lock) == :ok
      refute_received {:flock_released, _}
    end

    test "a shared waiter gets in once an exclusive lock is dropped", %{path: path} do
      pid = holder(path)
      task = Task.async(fn -> match?({:ok, _}, Flock.lock(path, mode: :shared)) end)
      assert Task.yield(task, 50) == nil
      unlock_holder(pid)
      assert Task.await(task)
    end

    test "a timed-out lock/2 leaves no lock or message behind", %{path: path} do
      pid = holder(path)
      assert Flock.lock(path, timeout: 50) == {:error, :timeout}
      refute_received {:flock_released, _}

      # Nothing of the timed-out attempt survives to hold up a later locker.
      unlock_holder(pid)
      eventually(fn -> available?(path) end)
      refute_receive {:flock_released, _}, 100
    end

    test "a waiter that exits stops waiting", %{path: path} do
      holder = holder(path)
      parent = self()

      waiter =
        spawn(fn ->
          Flock.lock(path)
          send(parent, :waiter_locked)
        end)

      Process.sleep(50)
      Process.exit(waiter, :kill)
      unlock_holder(holder)

      eventually(fn -> available?(path) end)
      refute_received :waiter_locked
    end

    test "waiters are served one after another", %{path: path} do
      pid = holder(path)
      parent = self()

      for i <- 1..5 do
        spawn(fn ->
          {:ok, lock} = Flock.lock(path)
          send(parent, {:got, i})
          Process.sleep(10)
          Flock.unlock(lock)
        end)
      end

      Process.sleep(50)
      unlock_holder(pid)

      for _ <- 1..5, do: assert_receive({:got, _}, 1_000)
    end

    test "repeated timeouts against a held lock leave nothing behind", %{path: path} do
      pid = holder(path)

      for _ <- 1..2048 do
        assert Flock.lock(path, timeout: 0) == {:error, :timeout}
      end

      refute_received {:flock_released, _}

      task = Task.async(fn -> match?({:ok, _}, Flock.lock(path, mode: :exclusive)) end)
      assert Task.yield(task, 50) == nil
      unlock_holder(pid)
      assert Task.await(task)
    end

    test "a timed-out shared waiter does not hold up a later exclusive one", %{path: path} do
      pid = holder(path)
      assert Flock.lock(path, mode: :shared, timeout: 0) == {:error, :timeout}

      task = Task.async(fn -> match?({:ok, _}, Flock.lock(path)) end)
      assert Task.yield(task, 50) == nil
      unlock_holder(pid)
      assert Task.await(task)
    end

    test "blocked waiters do not tie up dirty IO schedulers", %{path: path, tmp_dir: dir} do
      pid = holder(path)
      waiters = 2 * :erlang.system_info(:dirty_io_schedulers)
      for _ <- 1..waiters, do: spawn(fn -> Flock.lock(path) end)
      Process.sleep(100)

      other = Path.join(dir, "other")
      File.write!(other, "data")
      task = Task.async(fn -> File.read!(other) end)
      assert Task.yield(task, 1_000) == {:ok, "data"}

      unlock_holder(pid)
      eventually(fn -> available?(path) end)
    end
  end

  describe "with_lock/3" do
    test "runs the function under the lock and releases it", %{path: path} do
      assert Flock.with_lock(path, fn -> available?(path) end) == {:ok, false}
      assert available?(path)
    end

    test "releases the lock if the function raises", %{path: path} do
      assert_raise RuntimeError, fn -> Flock.with_lock(path, fn -> raise "boom" end) end
      assert available?(path)
    end

    test "passes on lock errors", %{path: path} do
      {:ok, lock} = Flock.try_lock(path)
      assert Flock.with_lock(path, [timeout: 0], fn -> flunk("ran") end) == {:error, :timeout}
      Flock.unlock(lock)
    end
  end

  describe "errors" do
    test "a missing parent directory is :enoent", %{tmp_dir: dir} do
      assert Flock.try_lock(Path.join([dir, "missing", "lock"])) == {:error, :enoent}
      assert Flock.lock(Path.join([dir, "missing", "lock"])) == {:error, :enoent}
    end

    test "a directory cannot be locked", %{tmp_dir: dir} do
      assert Flock.try_lock(dir) == {:error, :eisdir}
      assert Flock.try_lock(dir, mode: :shared) == {:error, :eisdir}
    end

    test "a FIFO is rejected without blocking", %{tmp_dir: dir} do
      fifo = Path.join(dir, "fifo")
      {_, 0} = System.cmd("mkfifo", [fifo])
      assert Flock.try_lock(fifo, mode: :shared) == {:error, :einval}
      assert Flock.try_lock(fifo) == {:error, :einval}
    end

    test "a path containing NUL is :einval", %{tmp_dir: dir} do
      assert Flock.try_lock(dir <> "/a\0b") == {:error, :einval}
    end

    test "invalid options raise", %{path: path} do
      assert_raise ArgumentError, fn -> Flock.lock(path, mode: :bogus) end
      assert_raise ArgumentError, fn -> Flock.lock(path, timeout: -1) end
      assert_raise ArgumentError, fn -> Flock.lock(path, bogus: true) end
      assert_raise ArgumentError, fn -> Flock.try_lock(path, timeout: 10) end
    end
  end
end
