### Added

- Hot code upgrades: a release upgrade can replace Flockit in a running VM
  while locks are held and callers are waiting. See "Hot code upgrades" in the
  `Flockit` docs for the appup. Upgrading from 1.0.0 still needs a VM restart.

### Fixed

- Deleting, purging and reloading `Flockit.NIF` no longer breaks locks taken
  before the reload or crashes the notifier.
