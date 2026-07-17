# WireProxyMenu

A native macOS menu bar wrapper for [wireproxy](https://github.com/windtf/wireproxy) — run a WireGuard tunnel as a SOCKS5/HTTP proxy without root, controlled from your menu bar.

> **wireproxy** ([github.com/windtf/wireproxy](https://github.com/windtf/wireproxy)) is an open-source tool that exposes a WireGuard tunnel as a local SOCKS5/HTTP proxy without requiring root or a system-level VPN. WireProxyMenu is a Mac GUI wrapper around it.

## Features

- Connect/disconnect wireproxy from the menu bar
- Auto-connects on launch using the last config
- Multiple config profiles
- Auto-reconnects if wireproxy exits unexpectedly
- Shows proxy address and connection time
- Shows your exit IP, fetched through the tunnel itself
- Monitors tunnel health and flags a dead tunnel (see [Tunnel health](#tunnel-health))
- Validates config before connecting, and warns if the file is readable by other users
- Detects port conflicts with a one-click fix

## Download

[Download the latest release](https://github.com/codexjdub/WireProxyMenu/releases/latest) — no need to build from source.

After downloading, unzip and run:
```bash
xattr -cr WireProxyMenu.app
open WireProxyMenu.app
```

> The `xattr` step is required because the app is ad-hoc signed. macOS will block it otherwise.

## Requirements

- macOS 13 or later (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- wireproxy binary

## Setup

**1. Get the wireproxy binary**

```bash
brew install wireproxy
cp $(which wireproxy) WireProxyMenu/wireproxy
```

Or download the `darwin_arm64` binary from the [wireproxy releases page](https://github.com/windtf/wireproxy/releases), rename it to `wireproxy`, and place it in the `WireProxyMenu/` folder.

**2. Build**

```bash
bash build.sh
```

**3. Run**

```bash
open build/WireProxyMenu.app
```

If macOS blocks the app, go to System Settings → Privacy & Security and click Open Anyway. Or run:

```bash
xattr -cr build/WireProxyMenu.app
open build/WireProxyMenu.app
```

## Usage

1. Click the menu bar icon
2. Click **Load Config…** and select your WireGuard `.conf` file
3. Click **Connect**

The proxy address (e.g. `127.0.0.1:1080`) is shown in the menu when connected. Press ⌘C with the menu open to copy it to the clipboard.

A few seconds after connecting, the menu also shows your exit IP — the public address your traffic leaves from, fetched through the tunnel itself. Press ⇧⌘C to copy it. Use **Check Connection** to re-fetch it and re-check tunnel health on demand.

## Tunnel health

"Connected" normally only means the wireproxy process is running. To let the app detect a tunnel that is up but not passing traffic, add these lines to the `[Interface]` section of your config:

```ini
CheckAlive = 1.1.1.1
CheckAliveInterval = 30
```

wireproxy will ping that address through the tunnel, and the app polls the result every 30 seconds. If the pings go stale, the menu shows **Connected (tunnel down)** and the menu bar icon dims. Without `CheckAlive`, health is unknown and the app stays quiet rather than guessing.

## Credits

Built with [Claude](https://claude.ai)

## Config format

Your `.conf` file must be a valid WireGuard config with a wireproxy proxy section. If you load a plain WireGuard config (e.g. one exported by your VPN provider), the app offers to add the `[Socks5]` section for you — pick a port and it's written into the file. Example:

```ini
[Interface]
PrivateKey = <your private key>
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <server public key>
Endpoint = example.com:51820
AllowedIPs = 0.0.0.0/0

[Socks5]
BindAddress = 127.0.0.1:1080
```
