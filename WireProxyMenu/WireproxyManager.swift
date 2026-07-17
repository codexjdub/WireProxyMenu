import Foundation
import Darwin
import CFNetwork

enum ManagerState {
    case disconnected
    case connected
    case reconnecting(attempt: Int)
}

struct TunnelStats {
    var lastHandshake: Date?  // nil = no handshake completed yet
    var rxBytes: Int64
    var txBytes: Int64
}

struct ResourceUsage {
    var cpuPercent: Double?  // nil until two samples exist to diff
    var residentBytes: Int64
}

@MainActor
class WireproxyManager {
    var configURL: URL?
    var onStateChange: (() -> Void)?
    var onFatalError: ((String) -> Void)?
    var onPortConflict: ((String) -> Void)?  // passes the conflicting address

    private(set) var proxyAddress: String?
    private(set) var proxyKind: String?  // "socks5" | "http" | "sni"
    private(set) var state: ManagerState = .disconnected
    /// nil = unknown (config has no CheckAlive, or not yet polled);
    /// false = wireproxy's /readyz reports the tunnel's pings are stale.
    private(set) var tunnelHealthy: Bool?
    private(set) var exitIP: String?
    private(set) var exitIPLatencyMs: Int?
    private(set) var exitIPFetching = false
    private(set) var tunnelStats: TunnelStats?
    /// True when the tunnel has completed no handshake well after launch —
    /// a near-certain sign of a wrong endpoint/key or blocked UDP.
    private(set) var handshakeMissing = false
    private(set) var resourceUsage: ResourceUsage?
    private var lastCPUSample: (time: Date, cpuNanos: Double)?
    private var healthPort: UInt16?
    private var healthTask: Task<Void, Never>?
    private var exitIPTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var process: Process?
    private var reconnectTask: Task<Void, Never>?
    private var intentionallyStopped = false
    private(set) var pendingRestart = false
    private let maxReconnectDelay: TimeInterval = 30

    func start() {
        // While a restart waits for the old process to die, launching now
        // could race it for the port — the termination handler will launch.
        guard case .disconnected = state, !pendingRestart else { return }
        intentionallyStopped = false
        launchProcess()
    }

    func stop() {
        intentionallyStopped = true
        pendingRestart = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopProbes()
        terminateProcess()
        proxyAddress = nil
        state = .disconnected
        onStateChange?()
    }

    /// Stop the current process and relaunch with the current config once the
    /// old process has fully exited — guarantees its port is released before
    /// the new launch's port check runs.
    func restart() {
        reconnectTask?.cancel()
        reconnectTask = nil

        guard let proc = process else {
            // Disconnected, or waiting out a reconnect delay — nothing holds
            // a port, so start immediately.
            state = .disconnected
            start()
            return
        }

        pendingRestart = true
        intentionallyStopped = true
        stopProbes()
        proxyAddress = nil
        state = .disconnected
        onStateChange?()
        proc.terminate()

        // Escalate to SIGKILL if the process ignores SIGTERM, so the
        // pending relaunch can't wait forever.
        let pid = proc.processIdentifier
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.pendingRestart, self.process === proc else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    /// Kill a wireproxy left over from a previous run that ended without
    /// cleanup (crash or force-quit). Only touches a live PID whose binary
    /// is this app's bundled wireproxy — never an unrelated process.
    func reapOrphanedProcess() {
        let stored = UserDefaults.standard.integer(forKey: "wireproxyPID")
        guard stored > 0 else { return }
        UserDefaults.standard.removeObject(forKey: "wireproxyPID")

        let pid = pid_t(stored)
        guard Darwin.kill(pid, 0) == 0 else { return }  // no longer running

        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return }
        let path = String(cString: buffer)
        guard path.hasSuffix("WireProxyMenu.app/Contents/MacOS/wireproxy") else { return }

        Darwin.kill(pid, SIGTERM)
    }

    private func launchProcess(attempt: Int = 0) {
        guard let configURL else { return }

        guard let binaryURL = Bundle.main.url(forAuxiliaryExecutable: "wireproxy") else {
            state = .disconnected
            onStateChange?()
            onFatalError?("wireproxy binary not found in app bundle.")
            return
        }

        let proxies = parseProxyAddresses(from: configURL)

        if let conflict = proxies.first(where: { isPortInUse($0.address) }) {
            state = .disconnected
            onStateChange?()
            onPortConflict?(conflict.address)
            return
        }

        // Display the address apps most commonly consume, not file order.
        let preferred = proxies.first(where: { $0.section == "socks5" })
            ?? proxies.first(where: { $0.section == "http" })
            ?? proxies.first
        proxyAddress = preferred?.address
        proxyKind = preferred?.section

        let proc = Process()
        proc.executableURL = binaryURL
        // -s silences the verbose WireGuard device log; fatal config errors
        // still reach stderr for the fast-exit error report.
        proc.arguments = ["-c", configURL.path, "-s"]

        // Expose wireproxy's health endpoint on a free localhost port so
        // /readyz can report real tunnel state (needs CheckAlive in config).
        healthPort = findFreePort()
        if let healthPort {
            proc.arguments?.append(contentsOf: ["-i", "127.0.0.1:\(healthPort)"])
        }

        // Drain stderr continuously so a chatty process can't fill the pipe
        // buffer and stall; keep only the tail for error reporting.
        let stderrBuffer = OutputBuffer()
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(chunk)
            }
        }

        let launchDate = Date()
        proc.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                // A stale handler from a process this manager already replaced
                // (stop() → start() before the old process finished dying)
                // must not touch state or trigger a reconnect.
                guard let self, self.process === proc else { return }
                self.process = nil
                self.stopProbes()
                UserDefaults.standard.removeObject(forKey: "wireproxyPID")

                if self.pendingRestart {
                    // The old process is confirmed dead, so its port is free —
                    // safe to launch with the current config now.
                    self.pendingRestart = false
                    self.intentionallyStopped = false
                    self.launchProcess()
                    return
                }

                if self.intentionallyStopped {
                    self.state = .disconnected
                    self.onStateChange?()
                    return
                }

                let ranBriefly = Date().timeIntervalSince(launchDate) < 3
                if status != 0, ranBriefly, attempt >= 2 {
                    self.proxyAddress = nil
                    self.state = .disconnected
                    self.onStateChange?()
                    let stderr = stderrBuffer.text
                    self.onFatalError?(
                        "wireproxy keeps exiting immediately — check the config."
                        + (stderr.isEmpty ? "" : "\n\n\(stderr)")
                    )
                    return
                }

                // A crash after a stable run restarts backoff from the beginning.
                self.scheduleReconnect(attempt: ranBriefly ? attempt : 0)
            }
        }

        do {
            try proc.run()
            process = proc
            // Remembered across runs so a crash/force-quit orphan can be
            // reaped at next launch.
            UserDefaults.standard.set(Int(proc.processIdentifier), forKey: "wireproxyPID")
            state = .connected
            onStateChange?()
            startHealthPolling()
            startExitIPFetch()
            startHandshakeWatch()
        } catch {
            proxyAddress = nil
            state = .disconnected
            onStateChange?()
            onFatalError?("Failed to start wireproxy: \(error.localizedDescription)")
        }
    }

    private func scheduleReconnect(attempt: Int) {
        guard !intentionallyStopped else { return }

        // Exponential backoff: 2, 4, 8, 16, 30 seconds
        let delay = min(pow(2.0, Double(attempt + 1)), maxReconnectDelay)
        state = .reconnecting(attempt: attempt + 1)
        onStateChange?()

        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.intentionallyStopped else { return }
                self.launchProcess(attempt: attempt + 1)
            }
        }
    }

    private func terminateProcess() {
        process?.terminate()
        process = nil
        UserDefaults.standard.removeObject(forKey: "wireproxyPID")
    }

    // MARK: - Tunnel health & exit IP

    private func stopProbes() {
        healthTask?.cancel()
        healthTask = nil
        exitIPTask?.cancel()
        exitIPTask = nil
        statsTask?.cancel()
        statsTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        handshakeMissing = false
        tunnelHealthy = nil
        exitIP = nil
        exitIPLatencyMs = nil
        exitIPFetching = false
        tunnelStats = nil
        resourceUsage = nil
        lastCPUSample = nil
    }

    /// Sample wireproxy's CPU and memory via libproc. Synchronous and cheap;
    /// called on the menu's 1s tick, so CPU% is the usage over the last tick.
    func sampleResourceUsage() {
        guard case .connected = state, let pid = process?.processIdentifier else { return }

        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return }

        // ri_*_time is in mach absolute time units, not nanoseconds.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let cpuNanos = Double(usage.ri_user_time &+ usage.ri_system_time)
            * Double(timebase.numer) / Double(timebase.denom)

        var cpuPercent: Double?
        let now = Date()
        if let last = lastCPUSample {
            let wall = now.timeIntervalSince(last.time)
            // Only trust a delta from a recent sample; after a gap (menu was
            // closed) this tick just re-baselines.
            if wall > 0.2, wall < 5 {
                cpuPercent = max(0, (cpuNanos - last.cpuNanos) / (wall * 1_000_000_000) * 100)
            }
        }
        lastCPUSample = (now, cpuNanos)
        resourceUsage = ResourceUsage(
            cpuPercent: cpuPercent,
            residentBytes: Int64(usage.ri_resident_size)
        )
    }

    /// Watch for the first handshake after launch. WireGuard handshakes
    /// lazily — only when traffic flows — so this is meaningful only for
    /// socks5/http configs, where our own exit IP fetch pushes traffic
    /// through the tunnel right after connect. No handshake 15s in means
    /// the tunnel never established (endpoint, key, or blocked UDP).
    private func startHandshakeWatch() {
        handshakeTask?.cancel()
        handshakeMissing = false
        guard proxyKind == "socks5" || proxyKind == "http",
              let healthPort,
              let url = URL(string: "http://127.0.0.1:\(healthPort)/metrics") else { return }

        handshakeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard case .connected = self.state else { return }

                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { continue }
                guard !Task.isCancelled, case .connected = self.state else { return }

                let missing = Self.parseTunnelStats(text).lastHandshake == nil
                if missing != self.handshakeMissing {
                    self.handshakeMissing = missing
                    self.onStateChange?()
                }
                // A completed handshake never un-happens; the watch is done.
                if !missing { return }
            }
        }
    }

    /// One-shot fetch of handshake/traffic counters from wireproxy's
    /// /metrics endpoint. Called on menu open and each tick while the menu
    /// is visible — the stats line only renders when eyes are on it.
    func refreshTunnelStats() {
        guard case .connected = state, let healthPort,
              let url = URL(string: "http://127.0.0.1:\(healthPort)/metrics") else { return }
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { return }
            guard let self, !Task.isCancelled else { return }
            guard case .connected = self.state else { return }
            self.tunnelStats = Self.parseTunnelStats(text)
            if self.tunnelStats?.lastHandshake != nil {
                self.handshakeMissing = false
            }
            self.onStateChange?()
        }
    }

    /// wireproxy's /metrics is WireGuard's UAPI dump (secrets redacted):
    /// key=value lines, one block per peer.
    private static func parseTunnelStats(_ text: String) -> TunnelStats {
        var latestHandshake: Int64 = 0
        var rx: Int64 = 0
        var tx: Int64 = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int64(parts[1]) else { continue }
            switch parts[0] {
            case "last_handshake_time_sec": latestHandshake = max(latestHandshake, value)
            case "rx_bytes":                rx += value
            case "tx_bytes":                tx += value
            default: break
            }
        }
        return TunnelStats(
            lastHandshake: latestHandshake > 0
                ? Date(timeIntervalSince1970: TimeInterval(latestHandshake))
                : nil,
            rxBytes: rx,
            txBytes: tx
        )
    }

    /// Re-run the health poll and exit IP fetch immediately (e.g. from a
    /// user-triggered "Check Connection").
    func refreshProbes() {
        guard case .connected = state else { return }
        startHealthPolling(initialDelayNanos: 0)
        startExitIPFetch(initialDelayNanos: 0)
        refreshTunnelStats()
        onStateChange?()  // both probes reset their values to unknown
    }

    private func startHealthPolling(initialDelayNanos: UInt64 = 5_000_000_000) {
        healthTask?.cancel()
        tunnelHealthy = nil
        guard let healthPort,
              let url = URL(string: "http://127.0.0.1:\(healthPort)/readyz") else { return }

        healthTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: initialDelayNanos)
            while !Task.isCancelled {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                var healthy: Bool?
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse {
                    let body = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Empty ping record means no CheckAlive in the config —
                    // /readyz is then always 200 and proves nothing.
                    healthy = (body == "{}" || body == "null") ? nil : (http.statusCode == 200)
                }
                guard let self, !Task.isCancelled else { return }
                guard case .connected = self.state else { return }
                if self.tunnelHealthy != healthy {
                    self.tunnelHealthy = healthy
                    self.onStateChange?()
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func startExitIPFetch(initialDelayNanos: UInt64 = 2_000_000_000) {
        exitIPTask?.cancel()
        exitIP = nil
        exitIPLatencyMs = nil
        exitIPFetching = false
        // SNI proxies can't tunnel arbitrary requests.
        guard proxyKind == "socks5" || proxyKind == "http",
              let address = proxyAddress,
              let lastColon = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: lastColon)...]) else { return }

        var host = String(address[..<lastColon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.isEmpty || host == "0.0.0.0" || host == "::" { host = "127.0.0.1" }

        let socks = proxyKind == "socks5"
        exitIPFetching = true
        exitIPTask = Task { [weak self] in
            // First handshake needs a moment; retry while the tunnel warms up.
            try? await Task.sleep(nanoseconds: initialDelayNanos)
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                guard let self, !Task.isCancelled else { return }
                guard case .connected = self.state else { return }
                if let result = await Self.fetchExitIP(host: host, port: port, socks: socks) {
                    guard !Task.isCancelled, case .connected = self.state else { return }
                    self.exitIP = result.ip
                    self.exitIPLatencyMs = result.latencyMs
                    self.exitIPFetching = false
                    self.onStateChange?()
                    return
                }
            }
            // All attempts failed — stop advertising a check in progress.
            guard let self, !Task.isCancelled else { return }
            self.exitIPFetching = false
            self.onStateChange?()
        }
    }

    private static func fetchExitIP(host: String, port: Int, socks: Bool) async -> (ip: String, latencyMs: Int)? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        if socks {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        } else {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let started = Date()
        guard let url = URL(string: "https://api.ipify.org"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let ip = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty, ip.count <= 45 else { return nil }
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        // Only ever display an actual IP literal, never response junk.
        var v4 = in_addr()
        var v6 = in6_addr()
        guard inet_pton(AF_INET, ip, &v4) == 1 || inet_pton(AF_INET6, ip, &v6) == 1 else {
            return nil
        }
        return (ip, latencyMs)
    }

    /// The preferred port if it's free, else the next free port above it
    /// (falling back to a kernel-assigned one). Used to suggest a sensible
    /// default in the proxy-fix dialog.
    func availablePort(preferring preferred: UInt16) -> UInt16 {
        var candidate = preferred
        for _ in 0..<100 {
            if !isPortInUse("127.0.0.1:\(candidate)") { return candidate }
            guard candidate < UInt16.max else { break }
            candidate += 1
        }
        return findFreePort() ?? preferred
    }

    private func findFreePort() -> UInt16? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // kernel assigns a free port
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard got == 0 else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func isPortInUse(_ address: String) -> Bool {
        guard let lastColon = address.lastIndex(of: ":") else { return false }
        var host = String(address[..<lastColon])
        let portStr = String(address[address.index(after: lastColon)...])
        guard UInt16(portStr) != nil else { return false }

        // IPv6 literals arrive bracketed: [::1]:1080
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.isEmpty || host == "0.0.0.0" { host = "127.0.0.1" }

        // getaddrinfo handles IPv4/IPv6 literals and local hostnames alike.
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, portStr, &hints, &result) == 0, let info = result else {
            return false
        }
        defer { freeaddrinfo(result) }

        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        return Darwin.bind(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0
    }

    private func parseProxyAddresses(from url: URL) -> [(section: String, address: String)] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var addresses: [(section: String, address: String)] = []
        var currentSection = ""
        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine
            if let comment = line.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                line = String(line[..<comment])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            } else if let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                if key == "bindaddress" {
                    let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        addresses.append((currentSection, value))
                    }
                }
            }
        }
        return addresses
    }
}

/// Rolling tail of process output, appendable from the pipe's readability
/// handler (background queue) and readable from the main actor.
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let maxBytes = 4096

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > maxBytes {
            data.removeFirst(data.count - maxBytes)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
