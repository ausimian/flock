### Added

- `Flock.lock/2`, `Flock.try_lock/2`, `Flock.unlock/1` and `Flock.with_lock/3`
  for exclusive and shared advisory locks via `flock(2)`.
- Waiting never blocks a thread: `lock/2` retries non-blocking attempts when
  the kernel reports a release (kqueue on macOS, inotify on Linux) and on a
  backstop timer (`:max_poll_interval`), and supports a `:timeout`.
- Locks are released on `unlock/1`, when the owning process exits, or when
  the lock is garbage collected.
