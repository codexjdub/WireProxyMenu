# Changelog

All notable changes to WireProxyMenu are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Tunnel stats line in the menu while connected: last handshake age and
  bytes received/sent through the tunnel (from wireproxy's /metrics),
  refreshed each second while the menu is open. A recent handshake proves
  the tunnel is alive even without `CheckAlive`; on an idle tunnel a
  growing age is normal
- The wireproxy version row shows the process's live CPU and memory usage
  while connected (e.g. "wireproxy 1.1.3 · 0.2% CPU · 28 MB"), sampled via
  libproc only while the menu is open
- Probes re-run automatically after wake from sleep and on network changes
  (debounced 2s), so the status is honest at the moments it's most likely
  to be stale
- The Config row is clickable: reveals the config in Finder (the original,
  for companion configs)
- The Exit IP line appends the fetch round-trip latency (e.g. "· 230ms");
  copying still copies only the IP

### Changed
- The Exit IP line shows "checking…" while a fetch is in flight (after
  connecting or clicking Check Connection), so a manual check is visibly
  doing something when the menu is reopened

## [1.2.0] - 2026-07-16

### Fixed
- Choosing "Keep File Untouched" for a config that was already a profile no
  longer leaves the original as a duplicate entry that re-prompts the fix
  dialog on every selection
- A companion whose original config vanished no longer alerts at every
  launch; it is cleaned up on launch the same way profile selection does
- Connect is disabled during the brief window where a restart waits for the
  old process to exit, preventing a spurious port-conflict alert
- The exit IP line only ever displays a valid IP literal
- Alert titles consistently say "WireProxyMenu"

### Changed
- wireproxy runs with `-s`, silencing verbose WireGuard device logging
  (fatal config errors still reach the error reporting)

### Added
- Tunnel health monitoring: wireproxy is launched with its health endpoint
  (`-i`) on a free localhost port and `/readyz` is polled every 30s; when the
  config has `CheckAlive`, a stale tunnel shows "Connected (tunnel down)" and
  dims the menu bar icon (without `CheckAlive`, health is reported as unknown,
  never falsely OK)
- Exit IP display: after connecting, the public IP is fetched through the
  proxy itself (SOCKS5 or HTTP) and shown in the menu; ⇧⌘C or click copies it.
  Skipped for SNI-only configs, which can't proxy arbitrary requests
- "Check Connection" menu item to re-run the health poll and exit IP fetch
  on demand while connected
- Loading a config that other users on the Mac can read offers a one-click
  permissions fix (chmod 600), since configs contain WireGuard private keys;
  "Ignore" is remembered per file
- README documents tunnel health, `CheckAlive` setup, and the exit IP line
- Loading a plain WireGuard config (no proxy section) now offers to add a
  `[Socks5]` section with a chosen port instead of just rejecting the file;
  a proxy section missing its `BindAddress` gets the same treatment. The
  suggested port is 1080 only if it's actually free, otherwise the next
  free port
- The fix dialog offers two paths: write into the file, or keep it untouched
  and store the proxy settings in an app-managed companion config that
  references the original via wireproxy's `WGConfig` include — the original
  keeps working with standard WireGuard clients. Companions live in
  Application Support, contain no secrets, are deleted with their profile,
  and a launch-time sweep removes any orphans

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

[Unreleased]: https://github.com/codexjdub/WireProxyMenu/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/codexjdub/WireProxyMenu/releases/tag/v1.2.0
[1.1.0]: https://github.com/codexjdub/WireProxyMenu/releases/tag/v1.1.0
[1.0.1]: https://github.com/codexjdub/WireProxyMenu/releases/tag/v1.0.1
[1.0.0]: https://github.com/codexjdub/WireProxyMenu/commit/03b0ce6
