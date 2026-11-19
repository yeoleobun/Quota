import AppKit
import QuotaBarCore
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController {
    private let store: QuotaStore
    private let viewModel: DashboardViewModel

    init(store: QuotaStore) {
        self.store = store
        self.viewModel = DashboardViewModel(initialProvider: store.settings.selectedProvider)
        let hostingController = NSHostingController(rootView: DashboardView(store: store, viewModel: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Usage Report"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 780, height: 580))
        window.minSize = NSSize(width: 700, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showDashboard() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
