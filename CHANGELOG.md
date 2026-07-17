# Changelog

All notable changes to WireProxyMenu are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Tunnel health monitoring: wireproxy is launched with its health endpoint
  (`-i`) on a free localhost port and `/readyz` is polled every 30s; when the
  config has `CheckAlive`, a stale tunnel shows "Connected (tunnel down)" and
  dims the menu bar icon (without `CheckAlive`, health is reported as unknown,
  never falsely OK)
- Exit IP display: after connecting, the public IP is fetched through the
  proxy itself (SOCKS5 or HTTP) and shown in the menu; ⇧⌘C or click copies it.
  Skipped for SNI-only configs, which can't proxy arbitrary requests

## [1.1.0] - 2026-07-16

### Added
- Support for wireproxy's new `[SNI]` proxy section in config validation
- Leftover wireproxy processes from a crash or force-quit are detected and
  killed at next launch (PID tracked across runs, binary path verified)
- Single-instance guard: a second copy of the app quits with an explanation
- `build.sh` produces a release-ready `WireProxyMenu.zip` from the pristine
  pre-iCloud copy, so the archived signature always verifies
- Connection elapsed time shows days once past 24h
- `CHANGELOG.md`

### Changed
- Bundled wireproxy updated from 1.1.2 to 1.1.3
- Config validation is now section-aware: commented-out keys no longer count,
  and error messages name the section a key is missing from
- "Change Config…" now reconnects automatically if the app was connected,
  matching profile-switch behavior
- "Kill & Retry" now kills only the process listening on the conflicting port
  (via `lsof`, run asynchronously) instead of every wireproxy on the machine,
  and no longer blocks the main thread
- Connection elapsed time updates live while the menu is open instead of on
  a 60s timer that couldn't fire during menu tracking
- Port conflict detection now checks every `BindAddress` in the config (not
  just the first) and handles IPv6 literals and hostnames via getaddrinfo
- The menu shows the `[Socks5]` bind address when a config has several proxy
  sections (falling back to `[Http]`, then file order)
- A restart that wireproxy's SIGTERM handling ignores escalates to SIGKILL
  after 3 seconds instead of waiting forever
- Reconnect backoff restarts from 2s after a connection that was stable,
  instead of resuming the previous attempt count
- `build.sh`: unique temp build directory per run, `set -euo pipefail`, and
  inside-out code signing instead of deprecated `--deep`

### Fixed
- Switching profiles while connected could orphan the new wireproxy process
  and trigger a spurious reconnect/port-conflict alert
- Switching between profiles that bind the same port raced the dying old
  process and could show a spurious port-conflict alert; the relaunch now
  waits for the old process to fully exit
- A port conflict or launch failure during auto-reconnect left the app stuck
  showing "Reconnecting…" with "Kill & Retry" silently doing nothing
- A config that wireproxy itself rejects caused a silent infinite reconnect
  loop; the app now gives up after three rapid failures and shows wireproxy's
  error output
- Copying the proxy address and disconnecting within 1.5s could permanently
  hide the proxy address line

## [1.0.1] - 2026-04-05

### Fixed
- Redundant `isRunning` check; state enum is now used consistently
- Copy feedback uses a proper boolean flag instead of string comparison
- `start()` was callable while already connected
- Config filename label separated from the Load Config action in the menu

## [1.0.0] - 2026-04-05

Initial release.

- Connect/disconnect wireproxy from the menu bar
- Auto-connect on launch using the last config
- Multiple config profiles
- Auto-reconnect with exponential backoff
- Proxy address display with ⌘C copy
- Config validation and port conflict detection

[Unreleased]: https://github.com/codexjdub/WireProxyMenu/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/codexjdub/WireProxyMenu/releases/tag/v1.1.0
[1.0.1]: https://github.com/codexjdub/WireProxyMenu/releases/tag/v1.0.1
[1.0.0]: https://github.com/codexjdub/WireProxyMenu/commit/03b0ce6
