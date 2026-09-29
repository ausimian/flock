# Flock

Advisory file locks for Elixir using `flock(2)`.

```elixir
{:ok, lock} = Flock.lock("/var/run/my_app.lock")
# ... only one holder at a time, across OS processes ...
:ok = Flock.unlock(lock)

# Or scoped:
{:ok, result} = Flock.with_lock("/var/run/my_app.lock", fn -> do_work() end)

# Shared (read) locks, timeouts and non-blocking attempts:
{:ok, lock} = Flock.lock(path, mode: :shared, timeout: 5_000)
{:error, :eagain} = Flock.try_lock(path)
```

- **Never blocks the VM.** Nothing ever sleeps in `flock(2)`: waiters make
  non-blocking attempts and are woken by the kernel's release notifications
  (kqueue on macOS, inotify on Linux), with a timed retry as a backstop.
- **No leaked locks.** A lock is released by `unlock/1`, when the process
  that took it exits, or when it is garbage collected.
- **POSIX errors.** Failures come back as `{:error, :enoent}`,
  `{:error, :eacces}` and so on.

See the [documentation](https://hexdocs.pm/flock) for the full semantics.

Tested on Linux and macOS. Other Unix systems should work, with timed retries
in place of release notifications, but are untested.

## Installation

```elixir
def deps do
  [
    {:flock, "~> 1.0"}
  ]
end
```

A C compiler and `make` are needed to build the NIF.
