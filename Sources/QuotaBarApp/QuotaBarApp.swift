import AppKit
import Darwin
import QuotaBarCore

@main
@MainActor
enum QuotaMain {
    private static var retainedDelegate: QuotaAppDelegate?

    static func main() {
        // Prevent SIGPIPE from silently terminating the app if a CLI child closes its pipe early
        signal(SIGPIPE, SIG_IGN)

        // Prevent macOS Automatic Termination (TAL) from killing the menu bar app when its popover closes
        ProcessInfo.processInfo.disableAutomaticTermination("Quota menu bar resident indicator")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = QuotaAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class QuotaAppDelegate: NSObject, NSApplicationDelegate {
    private var store: QuotaStore?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let quotaStore = QuotaStore()
        self.store = quotaStore
        self.statusBarController = StatusBarController(store: quotaStore)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
}
