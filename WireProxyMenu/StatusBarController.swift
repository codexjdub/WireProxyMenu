import AppKit
import Darwin
import UniformTypeIdentifiers

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    let manager = WireproxyManager()

    // Menu items
    private var statusMenuItem: NSMenuItem!
    private var proxyMenuItem: NSMenuItem!
    private var exitIPMenuItem: NSMenuItem!
    private var connectMenuItem: NSMenuItem!
    private var checkConnectionMenuItem: NSMenuItem!
    private var configNameMenuItem: NSMenuItem!   // disabled label: "Config: file.conf"
    private var loadConfigMenuItem: NSMenuItem!   // always "Load Config…"
    private var profilesMenuItem: NSMenuItem!
    private var versionMenuItem: NSMenuItem!

    // Connection start (elapsed time is rendered while the menu is open)
    private var connectedSince: Date?
    private var menuUpdateTimer: Timer?

    // Copy feedback
    private var restoreProxyTitleTask: DispatchWorkItem?
    private var isShowingCopyFeedback = false
    private var restoreExitIPTitleTask: DispatchWorkItem?
    private var isShowingExitIPCopyFeedback = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        super.init()
        setupMenu()
        setStatusTitle("Status: Disconnected")
        updateIcon(connected: false)

        manager.onStateChange    = { [weak self] in self?.updateUI() }
        manager.onFatalError     = { [weak self] msg in self?.showAlert(msg) }
        manager.onPortConflict   = { [weak self] addr in self?.showPortConflictAlert(addr) }

        manager.reapOrphanedProcess()
        fetchWireproxyVersion()
        restoreConfig()
    }

    // MARK: - Menu Setup

    private func setupMenu() {
        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        proxyMenuItem = NSMenuItem(title: "", action: #selector(copyProxyAddress), keyEquivalent: "c")
        proxyMenuItem.keyEquivalentModifierMask = .command
        proxyMenuItem.target = self
        proxyMenuItem.isHidden = true
        menu.addItem(proxyMenuItem)

        exitIPMenuItem = NSMenuItem(title: "", action: #selector(copyExitIP), keyEquivalent: "c")
        exitIPMenuItem.keyEquivalentModifierMask = [.command, .shift]
        exitIPMenuItem.target = self
        exitIPMenuItem.isHidden = true
        menu.addItem(exitIPMenuItem)

        menu.addItem(.separator())

        configNameMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        configNameMenuItem.isEnabled = false
        configNameMenuItem.isHidden = true
        menu.addItem(configNameMenuItem)

        loadConfigMenuItem = NSMenuItem(title: "Load Config…", action: #selector(loadConfig), keyEquivalent: "")
        loadConfigMenuItem.target = self
        menu.addItem(loadConfigMenuItem)

        profilesMenuItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        profilesMenuItem.submenu = NSMenu()
        menu.addItem(profilesMenuItem)

        connectMenuItem = NSMenuItem(title: "Connect", action: #selector(toggleConnection), keyEquivalent: "")
        connectMenuItem.target = self
        connectMenuItem.isEnabled = false
        menu.addItem(connectMenuItem)

        checkConnectionMenuItem = NSMenuItem(title: "Check Connection", action: #selector(checkConnection), keyEquivalent: "")
        checkConnectionMenuItem.target = self
        checkConnectionMenuItem.isHidden = true
        menu.addItem(checkConnectionMenuItem)

        menu.addItem(.separator())

        versionMenuItem = NSMenuItem(title: "wireproxy", action: nil, keyEquivalent: "")
        versionMenuItem.isEnabled = false
        menu.addItem(versionMenuItem)

        let quitItem = NSMenuItem(title: "Quit WireProxyMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        refreshProfilesMenu()
    }

    // The elapsed-time display only ticks while it is visible. The timer
    // must be added in .common modes — menu tracking runs the run loop in
    // eventTracking mode, where a default-mode timer never fires.
    func menuWillOpen(_ menu: NSMenu) {
        updateUI()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateUI() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuUpdateTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuUpdateTimer?.invalidate()
        menuUpdateTimer = nil
    }

    // MARK: - Config Management

    @objc private func loadConfig() {
        let panel = NSOpenPanel()
        panel.title = "Select WireGuard Config"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let confType = UTType(filenameExtension: "conf") {
            panel.allowedContentTypes = [confType]
        }
        activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard ensureValidConfig(at: url) else { return }
        let wasRunning: Bool
        switch manager.state {
        case .connected, .reconnecting: wasRunning = true
        case .disconnected:             wasRunning = false
        }
        setConfig(url)
        if wasRunning { manager.restart() }
    }

    private func setConfig(_ url: URL) {
        warnIfConfigPermissive(url)
        manager.configURL = url
        configNameMenuItem.title = "Config: \(url.lastPathComponent)"
        configNameMenuItem.isHidden = false
        loadConfigMenuItem.title = "Change Config…"
        connectMenuItem.isEnabled = true
        UserDefaults.standard.set(url.path, forKey: "lastConfigPath")
        addToProfiles(url.path)
        refreshProfilesMenu()
    }

    private func restoreConfig() {
        guard let path = UserDefaults.standard.string(forKey: "lastConfigPath") else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }

        guard ensureValidConfig(at: url) else { return }

        setConfig(url)
        manager.start()
    }

    // MARK: - Profiles

    private func savedProfiles() -> [String] {
        UserDefaults.standard.stringArray(forKey: "configProfiles") ?? []
    }

    private func addToProfiles(_ path: String) {
        var profiles = savedProfiles()
        if !profiles.contains(path) {
            profiles.append(path)
            UserDefaults.standard.set(profiles, forKey: "configProfiles")
        }
    }

    private func refreshProfilesMenu() {
        guard let submenu = profilesMenuItem.submenu else { return }
        submenu.removeAllItems()

        let activePath = UserDefaults.standard.string(forKey: "lastConfigPath")
        let profiles = savedProfiles()

        if profiles.isEmpty {
            let empty = NSMenuItem(title: "No profiles saved", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            // Detect duplicate filenames so we can show the parent folder
            let filenames = profiles.map { URL(fileURLWithPath: $0).lastPathComponent }
            let duplicates = Set(filenames.filter { name in filenames.filter { $0 == name }.count > 1 })

            for path in profiles {
                let url = URL(fileURLWithPath: path)
                let title = duplicates.contains(url.lastPathComponent)
                    ? "\(url.lastPathComponent)  — \(url.deletingLastPathComponent().lastPathComponent)"
                    : url.lastPathComponent
                let item = NSMenuItem(title: title, action: #selector(selectProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.state = (path == activePath) ? .on : .off
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove Active Profile", action: #selector(removeActiveProfile), keyEquivalent: "")
            remove.target = self
            remove.isEnabled = activePath != nil
            submenu.addItem(remove)
        }
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            showAlert("Config file not found:\n\(url.lastPathComponent)")
            var profiles = savedProfiles()
            profiles.removeAll { $0 == path }
            UserDefaults.standard.set(profiles, forKey: "configProfiles")
            refreshProfilesMenu()
            return
        }

        guard ensureValidConfig(at: url) else { return }

        let wasRunning: Bool
        switch manager.state {
        case .connected, .reconnecting: wasRunning = true
        case .disconnected:             wasRunning = false
        }

        setConfig(url)
        if wasRunning { manager.restart() }
    }

    @objc private func removeActiveProfile() {
        guard let path = UserDefaults.standard.string(forKey: "lastConfigPath") else { return }
        var profiles = savedProfiles()
        profiles.removeAll { $0 == path }
        UserDefaults.standard.set(profiles, forKey: "configProfiles")

        if let next = profiles.first {
            let wasRunning: Bool
            switch manager.state {
            case .connected, .reconnecting: wasRunning = true
            case .disconnected:             wasRunning = false
            }
            setConfig(URL(fileURLWithPath: next))
            if wasRunning { manager.restart() }
        } else {
            manager.stop()
            manager.configURL = nil
            connectMenuItem.isEnabled = false
            configNameMenuItem.isHidden = true
            loadConfigMenuItem.title = "Load Config…"
            UserDefaults.standard.removeObject(forKey: "lastConfigPath")
            refreshProfilesMenu()
        }
    }

    // MARK: - Connection

    @objc private func toggleConnection() {
        switch manager.state {
        case .connected, .reconnecting:
            manager.stop()
        case .disconnected:
            manager.start()
        }
    }

    @objc private func checkConnection() {
        manager.refreshProbes()
    }

    // MARK: - Copy Proxy

    @objc private func copyExitIP() {
        guard let ip = manager.exitIP else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)

        restoreExitIPTitleTask?.cancel()
        isShowingExitIPCopyFeedback = true
        exitIPMenuItem.title = "Copied!"

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingExitIPCopyFeedback = false
            if let ip = self.manager.exitIP {
                self.exitIPMenuItem.title = "Exit IP: \(ip)"
            }
        }
        restoreExitIPTitleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    @objc private func copyProxyAddress() {
        guard let addr = manager.proxyAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addr, forType: .string)

        restoreProxyTitleTask?.cancel()
        isShowingCopyFeedback = true
        proxyMenuItem.title = "Copied!"

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingCopyFeedback = false
            if let addr = self.manager.proxyAddress {
                self.proxyMenuItem.title = "Proxy: \(addr)"
            }
        }
        restoreProxyTitleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func clearCopyFeedback() {
        restoreProxyTitleTask?.cancel()
        restoreProxyTitleTask = nil
        isShowingCopyFeedback = false
        restoreExitIPTitleTask?.cancel()
        restoreExitIPTitleTask = nil
        isShowingExitIPCopyFeedback = false
    }

    // MARK: - UI Updates

    private func setStatusTitle(_ title: String) {
        statusMenuItem.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.labelColor]
        )
    }

    private func updateUI() {
        switch manager.state {
        case .connected:
            if connectedSince == nil { connectedSince = Date() }
            let elapsed = connectedSince.map { " · " + elapsedString(from: $0) } ?? ""
            let tunnelDown = manager.tunnelHealthy == false
            setStatusTitle(tunnelDown
                ? "Status: Connected (tunnel down)\(elapsed)"
                : "Status: Connected\(elapsed)")
            connectMenuItem.title = "Disconnect"
            checkConnectionMenuItem.isHidden = false
            updateIcon(connected: !tunnelDown)
            if let addr = manager.proxyAddress, !isShowingCopyFeedback {
                proxyMenuItem.title = "Proxy: \(addr)"
                proxyMenuItem.isHidden = false
            }
            if let ip = manager.exitIP {
                if !isShowingExitIPCopyFeedback {
                    exitIPMenuItem.title = "Exit IP: \(ip)"
                }
                exitIPMenuItem.isHidden = false
            } else {
                exitIPMenuItem.isHidden = true
            }

        case .reconnecting(let attempt):
            connectedSince = nil
            clearCopyFeedback()
            setStatusTitle("Status: Reconnecting… (attempt \(attempt))")
            connectMenuItem.title = "Cancel Reconnect"
            checkConnectionMenuItem.isHidden = true
            updateIcon(connected: false)
            proxyMenuItem.isHidden = true
            exitIPMenuItem.isHidden = true

        case .disconnected:
            connectedSince = nil
            clearCopyFeedback()
            setStatusTitle("Status: Disconnected")
            connectMenuItem.title = "Connect"
            checkConnectionMenuItem.isHidden = true
            updateIcon(connected: false)
            proxyMenuItem.isHidden = true
            exitIPMenuItem.isHidden = true
        }
    }

    private func updateIcon(connected: Bool) {
        let image = NSImage(named: "menubar")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !connected
    }

    // MARK: - Elapsed Time

    private func elapsedString(from date: Date) -> String {
        let elapsed = Int(-date.timeIntervalSinceNow)
        let days    = elapsed / 86400
        let hours   = (elapsed % 86400) / 3600
        let minutes = (elapsed % 3600) / 60
        if days > 0    { return "\(days)d \(hours)h" }
        if hours > 0   { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "just now"
    }

    // MARK: - wireproxy Version

    private func fetchWireproxyVersion() {
        guard let binaryURL = Bundle.main.url(forAuxiliaryExecutable: "wireproxy") else { return }
        DispatchQueue.global(qos: .background).async {
            let proc = Process()
            proc.executableURL = binaryURL
            proc.arguments = ["--version"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            guard (try? proc.run()) != nil else { return }
            proc.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Output format: "wireproxy, version 1.1.2" — take the last token
            let version = output.components(separatedBy: .whitespaces).last ?? ""
            Task { @MainActor [weak self] in
                self?.versionMenuItem.title = version.isEmpty ? "wireproxy" : "wireproxy \(version)"
            }
        }
    }

    // MARK: - Helpers

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showPortConflictAlert(_ address: String) {
        let alert = NSAlert()
        alert.messageText = "Port Already in Use"
        alert.informativeText = "\(address) is occupied by another process — likely a wireproxy that didn't shut down cleanly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill & Retry")
        alert.addButton(withTitle: "Cancel")
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let lastColon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: lastColon)...]) else {
            manager.start()
            return
        }

        // Kill only the process(es) listening on the conflicting port,
        // asynchronously so the main thread never blocks on lsof.
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.terminationHandler = { [weak self] _ in
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            for pid in output.split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }) {
                Darwin.kill(pid, SIGTERM)
            }
            // Brief pause for the port to be released, then retry
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.manager.start()
            }
        }
        guard (try? lsof.run()) != nil else {
            manager.start()
            return
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "WireProxy"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        activate()
        alert.runModal()
    }

    private enum ConfigIssue {
        case fatal(String)                 // structurally broken; user must fix
        case missingProxy                  // no proxy section at all
        case missingBindAddress(String)    // proxy section exists but has no BindAddress
    }

    /// Validate the config, offering to fix a missing/incomplete proxy
    /// section in place. Returns true when the config is usable.
    private func ensureValidConfig(at url: URL) -> Bool {
        switch configIssue(at: url) {
        case nil:
            return true
        case .fatal(let message):
            showAlert("Invalid config: \(message)")
            return false
        case .missingProxy:
            guard offerProxyFix(at: url, existingSection: nil) else { return false }
            return ensureValidConfig(at: url)
        case .missingBindAddress(let section):
            guard offerProxyFix(at: url, existingSection: section) else { return false }
            return ensureValidConfig(at: url)
        }
    }

    private func offerProxyFix(at url: URL, existingSection: String?) -> Bool {
        let alert = NSAlert()
        if let existingSection {
            alert.messageText = "Proxy Section Incomplete"
            alert.informativeText = "The [\(existingSection.capitalized)] section in \(url.lastPathComponent) has no BindAddress, which wireproxy requires. WireProxyMenu can add one so apps can connect through 127.0.0.1 on the port below. The file will be modified."
        } else {
            alert.messageText = "No Proxy Section"
            alert.informativeText = "\(url.lastPathComponent) is a plain WireGuard config with no proxy section. WireProxyMenu can add a SOCKS5 proxy so apps can connect through 127.0.0.1 on the port below. The file will be modified."
        }
        alert.alertStyle = .informational

        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        // Suggest 1080 only if it's actually free right now.
        portField.stringValue = String(manager.availablePort(preferring: 1080))
        portField.placeholderString = "Port (1–65535)"
        alert.accessoryView = portField

        alert.addButton(withTitle: existingSection == nil ? "Add SOCKS5 Proxy" : "Add BindAddress")
        alert.addButton(withTitle: "Cancel")
        activate()
        alert.window.initialFirstResponder = portField
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces)), port > 0 else {
            showAlert("“\(portField.stringValue)” is not a valid port number.")
            return false
        }

        let bindLine = "BindAddress = 127.0.0.1:\(port)"
        if let existingSection {
            return insertLine(bindLine, afterSectionHeader: existingSection, in: url)
        } else {
            return appendToConfig("\n[Socks5]\n\(bindLine)\n", at: url)
        }
    }

    private func appendToConfig(_ block: String, at url: URL) -> Bool {
        guard var content = try? String(contentsOf: url, encoding: .utf8) else {
            showAlert("Could not read \(url.lastPathComponent).")
            return false
        }
        if !content.hasSuffix("\n") { content += "\n" }
        content += block
        return writeConfig(content, to: url)
    }

    private func insertLine(_ line: String, afterSectionHeader section: String, in url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            showAlert("Could not read \(url.lastPathComponent).")
            return false
        }
        var lines = content.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var stripped = rawLine
            if let comment = stripped.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                stripped = String(stripped[..<comment])
            }
            stripped = stripped.trimmingCharacters(in: .whitespaces).lowercased()
            if stripped == "[\(section)]" {
                lines.insert(line, at: index + 1)
                return writeConfig(lines.joined(separator: "\n"), to: url)
            }
        }
        showAlert("Could not find the [\(section.capitalized)] section in \(url.lastPathComponent).")
        return false
    }

    private func writeConfig(_ content: String, to url: URL) -> Bool {
        // Atomic writes replace the file, so re-apply its permissions.
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            if let perms {
                try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            }
            return true
        } catch {
            showAlert("Could not update \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Configs contain WireGuard private keys; offer to lock down files that
    /// other users on the machine can read. "Ignore" is remembered per path.
    private func warnIfConfigPermissive(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perms = attrs[.posixPermissions] as? NSNumber else { return }
        let mode = perms.uint16Value
        guard mode & 0o077 != 0 else { return }  // group/other already have no access

        let ignoredKey = "permissionWarningIgnored"
        let ignored = UserDefaults.standard.stringArray(forKey: ignoredKey) ?? []
        guard !ignored.contains(url.path) else { return }

        let alert = NSAlert()
        alert.messageText = "Config Readable by Other Users"
        alert.informativeText = "\(url.lastPathComponent) contains your WireGuard private key, but its permissions (\(String(format: "%o", mode))) allow other users on this Mac to read it. Restrict it to your user only?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Fix Permissions")
        alert.addButton(withTitle: "Ignore")
        activate()

        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(ignored + [url.path], forKey: ignoredKey)
            return
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            showAlert("Could not change permissions: \(error.localizedDescription)")
        }
    }

    private func configIssue(at url: URL) -> ConfigIssue? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .fatal("Could not read file.")
        }

        // Section-aware INI walk so commented-out keys don't count.
        var keysBySection = [String: Set<String>]()
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
                if keysBySection[currentSection] == nil {
                    keysBySection[currentSection] = []
                }
            } else if let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                keysBySection[currentSection, default: []].insert(key)
            }
        }

        guard let interface = keysBySection["interface"] else { return .fatal("Missing [Interface] section.") }
        guard interface.contains("privatekey") else { return .fatal("Missing PrivateKey in [Interface].") }
        guard let peer = keysBySection["peer"] else { return .fatal("Missing [Peer] section.") }
        guard peer.contains("endpoint") else { return .fatal("Missing Endpoint in [Peer].") }

        let proxySections = ["socks5", "http", "sni"].filter { keysBySection[$0] != nil }
        if proxySections.isEmpty {
            return .missingProxy
        }
        if !proxySections.contains(where: { keysBySection[$0]?.contains("bindaddress") == true }) {
            return .missingBindAddress(proxySections[0])
        }
        return nil
    }
}
