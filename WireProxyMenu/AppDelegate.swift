import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices blocks double-launching the same bundle, but not a
        // second copy at a different path (or `open -n`).
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            let alert = NSAlert()
            alert.messageText = "WireProxyMenu is already running"
            alert.informativeText = "Another copy of WireProxyMenu is already active. This one will quit."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.manager.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
