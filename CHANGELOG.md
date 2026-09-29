# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## 1.0.0 - 2026-09-29

First stable release. The public API (`Flock.lock/2`, `Flock.try_lock/2`,
`Flock.unlock/1` and `Flock.with_lock/3`) now follows semantic versioning.
Tested on Linux and macOS.

### Added

- Exclusive and shared advisory file locks via `flock(2)`, interoperating
  with other `flock(2)` users, in this VM or other OS processes.
- Waiting never blocks a BEAM scheduler or thread: `lock/2` wakes on the
  kernel's release notifications (kqueue on macOS, inotify on Linux), with
  timed retries as a backstop, tunable with `:max_poll_interval`.
- `lock/2` takes a `:timeout` and never returns a lock after it expires.
- Locks are released by `unlock/1`, when the owning process exits, or when
  the lock is garbage collected.
- Errors are POSIX reasons such as `:enoent` and `:eacces`; `try_lock/2`
  returns `{:error, :eagain}` for a busy lock.
