# Flockit

Elixir library for advisory file locks via `flock(2)`, backed by a C NIF in
`c_src/flockit_nif.c`. Public API is in `lib/flockit.ex`; `Flockit.NIF` and
`Flockit.Notifier` are internal.

## Commands

- `mix precommit` before every commit. It runs `compile --warnings-as-errors`,
  `deps.unlock --unused`, `format`, `credo --strict` and `test`; don't run the
  steps individually instead.
- `make analyze` runs the clang static analyzer over the NIF, and
  `mix dialyzer` the type checks. CI runs both.
- Test on macOS **and** Linux. The release notifications differ per platform
  (kqueue vs inotify), so a change that passes on one proves nothing about the
  other.

## How it works

Nothing ever blocks in `flock()`. `lock/2` makes `LOCK_NB` attempts; between
them the caller waits for a `{:flockit_released, lock}` message or a backoff
timer. The messages come from one VM-wide notify descriptor (kqueue
`NOTE_FUNLOCK` on macOS, inotify `IN_CLOSE_*` on Linux) that `Flockit.Notifier`
watches with `enif_select`. Notifications only ever affect latency; the timed
retries alone must keep the library correct.

Invariants that earlier designs got wrong, so keep them:

- **Never block a normal scheduler.** Anything that can touch the filesystem
  (open, flock, unlock, close) runs in a dirty NIF. Resource callbacks (`down`,
  destructor) only queue descriptors for the notifier to close.
- **Bound work on normal schedulers.** `drain` handles at most `DRAIN_EVENTS`
  kernel events and `DRAIN_STEPS` units of delivery per call, then returns
  `:more`.
- **No threads, no signals.** The library runs code only inside NIF calls and
  resource callbacks.
- **Register before attempting.** A waiter calls `watch` before its next
  attempt so that a release in between still produces a message; `try` clears
  the lock's `notified` flag before attempting for the same reason.
- **Lock ordering:** a lock's own mutex before `registry_mtx`.
- **Upgradable state.** Everything that outlives a NIF call lives in
  `state_t`, never in globals, and nothing in it points into the library
  itself. Bump `LAYOUT_VERSION` whenever `state_t` or anything it reaches
  changes in layout or meaning, and say in `RELEASE.md` that the version
  needs a VM restart.
- **No late locks.** `lock/2` never returns a lock after its `:timeout`
  expires (`timeout: 0` is a single attempt).

Tests that exercise these invariants should fail when the invariant is
broken. Check new ones by temporarily breaking the code they protect.

## Conventions

- Conventional Commits; imperative, lowercase subjects of at most 72 chars.
- Update `RELEASE.md` (Keep a Changelog sections) on every change that users
  would notice. `CHANGELOG.md` is generated from it at release time.
- `@version` in `mix.exs` is the single source of truth. Release with
  `mix publisho <level>`, which tags bare semver (no `v` prefix).
