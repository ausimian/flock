defmodule Flockit do
  @moduledoc """
  Advisory file locks using `flock(2)`.

      {:ok, lock} = Flockit.lock("/tmp/my.lock")
      # ... critical section ...
      :ok = Flockit.unlock(lock)

  or, equivalently:

      {:ok, result} = Flockit.with_lock("/tmp/my.lock", fn -> critical_section() end)

  The lock file is created if it does not exist, and is never written to or
  removed. Locks are advisory: they only exclude other `flock(2)` users, in
  this VM or in other OS processes.

  ## Lifetime

  A lock is released by whichever comes first:

    * `unlock/1`, which may be called from any process;
    * the exit of the process that acquired it, for any reason;
    * garbage collection of the last reference to the lock.

  Rely on `unlock/1` rather than garbage collection for prompt release.

  ## Each call is a separate lock

  `flock(2)` locks belong to an open file, and every call here opens the file
  afresh. Two calls from the *same* process therefore conflict just like calls
  from different processes: a second exclusive `lock/2` on a path the caller
  already holds waits for the caller itself.

  ## Waiting

  `lock/2` never blocks a thread in `flock(2)`. It makes non-blocking attempts,
  and between them waits in the calling process for the kernel to report that
  the file may have been unlocked:

    * on macOS, a kqueue `NOTE_FUNLOCK` event, raised by every unlock,
      including when the holder closes the file or exits;
    * on Linux, an inotify close event, raised when the holder closes the file
      or exits.

  Attempts are also retried on a timer, backing off to at most
  `:max_poll_interval` milliseconds (default 250). That covers releases the
  kernel does not report: on Linux, another program unlocking without closing
  the file, and anywhere, holders on other hosts of a network filesystem. On
  other platforms the timer is all there is.

  A caller that times out or exits simply stops waiting; nothing is left
  behind.

  Release notifications are pumped by a process in the `:flockit` application,
  which also closes the files of locks released by an owner exiting or by
  garbage collection, off the normal schedulers. It starts automatically when
  `:flockit` is a dependency. Without it, locks still work, but waiters rely on
  timed retries and such files are closed during later calls into the
  library.

      config :flockit, max_poll_interval: 250

  ## Platform notes

  Tested on Linux and macOS. Other Unix systems should work, with timed retries
  in place of release notifications, but are untested. Only regular files can be locked: directories give `{:error, :eisdir}` and
  other special files `{:error, :einval}`. On NFS, `flock(2)` is emulated with
  byte-range locks, so exclusive locks need write access to the lock file.

  ## Hot code upgrades

  A release upgrade can replace Flockit in a running VM. The new version takes
  over held locks, waiting callers and release notifications from the old one.
  In the appup, load the new modules over the old ones, with soft purges for
  the two modules that callers spend time in:

      {load_module, 'Elixir.Flockit.NIF', soft_purge, soft_purge, []},
      {load_module, 'Elixir.Flockit', soft_purge, soft_purge, []}

  Callers waiting in `lock/2` or running `with_lock/3` are executing
  `Flockit`, and callers in the middle of a call into the NIF are executing
  `Flockit.NIF`, so they keep running the old version for a while. A soft
  post-purge leaves them be; with `brutal_purge`, they are killed when the
  release is made permanent. A soft pre-purge makes a later upgrade that
  finds callers still running code from the version before this one fail
  with `{:error, {:old_processes, module}}` before it changes anything; with
  `brutal_purge`, they are killed instead. Either way, a killed caller's locks
  are released. Removing the application and adding it again, as
  `restart_application` does, is not supported.

  An upgrade to a version whose internal state is incompatible is refused:
  `Flockit.NIF` fails to load, and the release handler restarts the system on
  the old release. The changelog says when a version needs a restart. Upgrading
  from 1.0.0 needs a VM restart.
  """

  alias Flockit.NIF

  @min_poll_interval 10

  @typedoc "A lock acquired by `lock/2` or `try_lock/2`."
  @opaque t :: reference()

  @typedoc "`:exclusive` for a write lock (the default), `:shared` for a read lock."
  @type mode :: :exclusive | :shared

  @type lock_option :: {:mode, mode()} | {:timeout, timeout()}

  @doc """
  Acquires a lock on `path`, waiting until it is available.

  ## Options

    * `:mode` - `:exclusive` (default) or `:shared`.
    * `:timeout` - how long to wait, in milliseconds, or `:infinity`
      (default). Returns `{:error, :timeout}` when it expires; a lock is
      never returned after that. `0` makes a single attempt, like
      `try_lock/2` but with `{:error, :timeout}` for a busy lock.

  Other errors are POSIX reasons from opening or locking the file, such as
  `:enoent` when the parent directory does not exist.
  """
  @spec lock(Path.t(), [lock_option()]) :: {:ok, t()} | {:error, :timeout | File.posix()}
  def lock(path, opts \\ []) do
    opts = Keyword.validate!(opts, mode: :exclusive, timeout: :infinity)
    timeout = validate_timeout!(opts[:timeout])
    deadline = deadline(timeout)

    case NIF.acquire(to_binary(path), exclusive?(opts[:mode])) do
      {:ok, lock} ->
        # The attempt may have queued for a dirty scheduler past a short
        # deadline. A zero timeout is a single attempt, like try_lock/2.
        if timeout != 0 and time_left(deadline) == 0 do
          give_up(lock, {:error, :timeout})
        else
          {:ok, lock}
        end

      {:busy, lock} ->
        # Registering before the next attempt means a release between the two
        # still produces a notification.
        _ = NIF.watch(lock)
        max = Application.get_env(:flockit, :max_poll_interval, 250)
        attempt(lock, deadline, @min_poll_interval, max)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Acquires a lock on `path` only if it is available right now.

  Returns `{:error, :eagain}` if a conflicting lock is held. Accepts the
  `:mode` option of `lock/2`.
  """
  @spec try_lock(Path.t(), mode: mode()) :: {:ok, t()} | {:error, File.posix()}
  def try_lock(path, opts \\ []) do
    opts = Keyword.validate!(opts, mode: :exclusive)

    case NIF.acquire(to_binary(path), exclusive?(opts[:mode])) do
      {:busy, lock} ->
        :ok = NIF.release(lock)
        {:error, :eagain}

      result ->
        result
    end
  end

  @doc """
  Releases `lock`. Releasing a lock that is already released is a no-op.
  """
  @spec unlock(t()) :: :ok
  def unlock(lock) when is_reference(lock), do: NIF.release(lock)

  @doc """
  Runs `fun` while holding a lock on `path`, and releases it afterwards, even
  if `fun` raises. Takes the same options as `lock/2`.
  """
  @spec with_lock(Path.t(), [lock_option()], (-> result)) ::
          {:ok, result} | {:error, :timeout | File.posix()}
        when result: var
  def with_lock(path, opts \\ [], fun) when is_function(fun, 0) do
    with {:ok, lock} <- lock(path, opts) do
      try do
        {:ok, fun.()}
      after
        unlock(lock)
      end
    end
  end

  # Every attempt after the first starts before the deadline, and a lock
  # taken by an attempt that finishes after it is given back, so a timed-out
  # call never returns a lock late.
  defp attempt(lock, deadline, interval, max) do
    with true <- time_left(deadline) != 0,
         :ok <- NIF.try(lock),
         true <- time_left(deadline) != 0 do
      # try/1 unregistered the lock, so no notification can follow this flush.
      flush(lock)
      {:ok, lock}
    else
      false -> give_up(lock, {:error, :timeout})
      {:error, :eagain} -> wait(lock, deadline, interval, max)
      {:error, _} = error -> give_up(lock, error)
    end
  end

  defp wait(lock, deadline, interval, max) do
    receive do
      {:flockit_released, ^lock} -> attempt(lock, deadline, interval, max)
    after
      min(interval, time_left(deadline)) ->
        attempt(lock, deadline, min(interval * 2, max), max)
    end
  end

  defp give_up(lock, result) do
    :ok = NIF.release(lock)
    flush(lock)
    result
  end

  # Once a lock is unregistered, any notification for it is already in the
  # mailbox: the notifier sends while holding the registry mutex.
  defp flush(lock) do
    receive do
      {:flockit_released, ^lock} -> flush(lock)
    after
      0 -> :ok
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp time_left(:infinity), do: :infinity
  defp time_left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp exclusive?(:exclusive), do: true
  defp exclusive?(:shared), do: false

  defp exclusive?(mode) do
    raise ArgumentError, "expected :mode to be :exclusive or :shared, got: #{inspect(mode)}"
  end

  defp validate_timeout!(:infinity), do: :infinity
  defp validate_timeout!(ms) when is_integer(ms) and ms >= 0, do: ms

  defp validate_timeout!(other) do
    raise ArgumentError,
          "expected :timeout to be a non-negative integer or :infinity, got: #{inspect(other)}"
  end

  defp to_binary(path), do: IO.chardata_to_string(path)
end
