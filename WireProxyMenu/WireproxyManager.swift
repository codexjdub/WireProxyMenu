import Foundation
import Darwin

enum ManagerState {
    case disconnected
    case connected
    case reconnecting(attempt: Int)
}

@MainActor
class WireproxyManager {
    var configURL: URL?
    var onStateChange: (() -> Void)?
    var onFatalError: ((String) -> Void)?
    var onPortConflict: ((String) -> Void)?  // passes the conflicting address

    private(set) var proxyAddress: String?
    private(set) var state: ManagerState = .disconnected
    private var process: Process?
    private var reconnectTask: Task<Void, Never>?
    private var intentionallyStopped = false
    private var pendingRestart = false
    private let maxReconnectDelay: TimeInterval = 30

    func start() {
        guard case .disconnected = state else { return }
        intentionallyStopped = false
        pendingRestart = false
        launchProcess()
    }

    func stop() {
        intentionallyStopped = true
        pendingRestart = false
        reconnectTask?.cancel()
        reconnectTask = nil
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
        proxyAddress = proxies.first(where: { $0.section == "socks5" })?.address
            ?? proxies.first(where: { $0.section == "http" })?.address
            ?? proxies.first?.address

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["-c", configURL.path]

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
