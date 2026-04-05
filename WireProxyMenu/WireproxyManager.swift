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
    private let maxReconnectDelay: TimeInterval = 30

    func start() {
        guard case .disconnected = state else { return }
        intentionallyStopped = false
        launchProcess()
    }

    func stop() {
        intentionallyStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        terminateProcess()
        proxyAddress = nil
        state = .disconnected
        onStateChange?()
    }

    private func launchProcess(attempt: Int = 0) {
        guard let configURL else { return }

        guard let binaryURL = Bundle.main.url(forAuxiliaryExecutable: "wireproxy") else {
            onFatalError?("wireproxy binary not found in app bundle.")
            return
        }

        proxyAddress = parseProxyAddress(from: configURL)

        if let addr = proxyAddress, isPortInUse(addr) {
            onPortConflict?(addr)
            return
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["-c", configURL.path]
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil

                if self.intentionallyStopped {
                    self.state = .disconnected
                    self.onStateChange?()
                    return
                }

                self.scheduleReconnect(attempt: attempt)
            }
        }

        do {
            try proc.run()
            process = proc
            state = .connected
            onStateChange?()
        } catch {
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
    }

    nonisolated deinit {
        process?.terminate()
    }

    private func isPortInUse(_ address: String) -> Bool {
        guard let lastColon = address.lastIndex(of: ":") else { return false }
        let host = String(address[..<lastColon])
        let portStr = String(address[address.index(after: lastColon)...])
        guard let port = UInt16(portStr) else { return false }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let resolvedHost = (host.isEmpty || host == "0.0.0.0") ? "127.0.0.1" : host
        inet_pton(AF_INET, resolvedHost, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0  // bind failed → port is already in use
    }

    private func parseProxyAddress(from url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bindaddress") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    return parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}
