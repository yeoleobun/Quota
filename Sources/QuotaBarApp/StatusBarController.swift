import AppKit
import Combine
import QuotaBarCore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: QuotaStore
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let dotOverlayView = WeeklyDotOverlayView()
    private var dashboardWindowController: DashboardWindowController?

    private var cancellables = Set<AnyCancellable>()
    private var hoverOpenWorkItem: DispatchWorkItem?
    private var hoverDismissTimer: Timer?

    private var isMenuOpen = false
    private var pendingHoverOpen = false
    private var openedByHover = false
    private var lastMenuCloseTime: Date = .distantPast

    private static let menuMinimumWidth: CGFloat = 300

    init(store: QuotaStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.menu = NSMenu(title: "Quota")
        super.init()

        configureNativeMenu()
        configureStatusButton()
        bindStore()
    }

    private func configureNativeMenu() {
        menu.minimumWidth = Self.menuMinimumWidth
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly

        // Colored weekly watermark dot overlay (Green / Yellow / Red)
        dotOverlayView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dotOverlayView)

        // Passive hover overlay so hovering over the beer icon opens the genuine NSMenu
        let trackingOverlay = HoverTrackingOverlayView(
            onMouseEntered: { [weak self] in
                self?.handleButtonHoverEntered()
            },
            onMouseExited: { [weak self] in
                self?.handleButtonHoverExited()
            }
        )
        trackingOverlay.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(trackingOverlay)

        NSLayoutConstraint.activate([
            dotOverlayView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            dotOverlayView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            dotOverlayView.topAnchor.constraint(equalTo: button.topAnchor),
            dotOverlayView.bottomAnchor.constraint(equalTo: button.bottomAnchor),

            trackingOverlay.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            trackingOverlay.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            trackingOverlay.topAnchor.constraint(equalTo: button.topAnchor),
            trackingOverlay.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        updateStatusButtonAppearance()
    }

    private func bindStore() {
        store.$snapshots
            .combineLatest(store.$settings, store.$updateState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.updateStatusButtonAppearance()
                if self.isMenuOpen, self.menu.highlightedItem == nil {
                    self.rebuildMenuItems()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusButtonAppearance() {
        guard let button = statusItem.button else { return }
        let watermark = store.selectedWeeklyWatermark
        button.title = ""
        button.imagePosition = .imageOnly
        statusItem.length = NSStatusItem.squareLength
        button.image = BeerMugIcon.makeMenuBarImage(hasStatusDot: watermark != nil)
        dotOverlayView.watermark = watermark
    }

    // MARK: - Hover-to-Open & Smart Hover Dismiss for Native NSMenu

    private func handleButtonHoverEntered() {
        hoverOpenWorkItem?.cancel()
        guard !isMenuOpen else { return }
        guard Date().timeIntervalSince(lastMenuCloseTime) > 0.35 else { return }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isMenuOpen else { return }
                guard NSEvent.pressedMouseButtons == 0 else { return }
                guard self.isCursorNearButton() else { return }

                self.pendingHoverOpen = true
                self.statusItem.button?.performClick(nil)
                self.pendingHoverOpen = false
            }
        }
        hoverOpenWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func handleButtonHoverExited() {
        hoverOpenWorkItem?.cancel()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMenuItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        hoverOpenWorkItem?.cancel()
        isMenuOpen = true
        openedByHover = pendingHoverOpen && (NSEvent.pressedMouseButtons == 0)

        if openedByHover {
            startHoverDismissTimer()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        stopHoverDismissTimer()
        isMenuOpen = false
        openedByHover = false
        lastMenuCloseTime = Date()
    }

    private func startHoverDismissTimer() {
        stopHoverDismissTimer()
        let timer = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMenuOpen, self.openedByHover else { return }
                if !self.isCursorInsideAnyMenuWindowOrButton(padding: 20) {
                    self.menu.cancelTracking()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        hoverDismissTimer = timer
    }

    private func stopHoverDismissTimer() {
        hoverDismissTimer?.invalidate()
        hoverDismissTimer = nil
    }

    private func isCursorNearButton(padding: CGFloat = 8) -> Bool {
        guard let btnWin = statusItem.button?.window else { return false }
        return btnWin.frame.insetBy(dx: -padding, dy: -padding).contains(NSEvent.mouseLocation)
    }

    private func isCursorInsideAnyMenuWindowOrButton(padding: CGFloat) -> Bool {
        let mouse = NSEvent.mouseLocation
        if let btnWin = statusItem.button?.window,
           btnWin.frame.insetBy(dx: -padding, dy: -padding).contains(mouse)
        {
            return true
        }
        for win in NSApplication.shared.windows where win.isVisible {
            let className = String(describing: type(of: win))
            if className.contains("Menu") {
                if win.frame.insetBy(dx: -padding, dy: -padding).contains(mouse) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Native NSMenu Construction

    private func rebuildMenuItems() {
        menu.removeAllItems()

        // 1. Top Status Header
        let statusHeader = NSMenuItem(title: statusHeaderTitle, action: nil, keyEquivalent: "")
        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        menu.addItem(.separator())

        // 2. Agent Sections (Codex & Antigravity)
        let providers = store.settings.providerOrder
        let now = Date()

        for (index, providerID) in providers.enumerated() {
            let snap = store.snapshot(for: providerID)
            let isSelected = (store.settings.selectedProvider == providerID)

            // Selectable Agent Header Row with native ✓, email subtitle, and plan NSMenuItemBadge
            let agentItem = NSMenuItem(
                title: providerID.displayName,
                action: #selector(handleSelectProvider(_:)),
                keyEquivalent: ""
            )
            agentItem.target = self
            agentItem.representedObject = providerID.rawValue
            agentItem.state = isSelected ? .on : .off
            agentItem.isEnabled = true

            if let email = snap.accountEmail, !email.isEmpty {
                agentItem.subtitle = email
            }
            if let plan = snap.planLabel, !plan.isEmpty {
                agentItem.badge = NSMenuItemBadge(string: plan)
            }
            menu.addItem(agentItem)

            // Agent Quota Windows / Status
            appendQuotaRows(for: snap, now: now)

            if index < providers.count - 1 {
                menu.addItem(.separator())
            }
        }

        menu.addItem(.separator())

        // 2.5 Usage & Token Dashboard
        let dashboardItem = NSMenuItem(
            title: "Usage Dashboard…",
            action: #selector(handleOpenDashboard(_:)),
            keyEquivalent: "d"
        )
        dashboardItem.target = self
        dashboardItem.isEnabled = true
        dashboardItem.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Usage Dashboard")
        menu.addItem(dashboardItem)

        menu.addItem(.separator())

        // 3. Weekly Watermark Dot Toggle + Refresh Interval Submenu
        let indicatorItem = NSMenuItem(
            title: "Weekly indicator",
            action: #selector(handleToggleWeeklyIndicator(_:)),
            keyEquivalent: ""
        )
        indicatorItem.target = self
        indicatorItem.isEnabled = true
        indicatorItem.state = store.settings.showWeeklyIndicator ? .on : .off
        menu.addItem(indicatorItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "")
        refreshItem.isEnabled = true
        refreshItem.badge = NSMenuItemBadge(string: "\(store.settings.refreshIntervalMinutes)m")

        let refreshSubmenu = NSMenu(title: "Refresh")
        refreshSubmenu.autoenablesItems = false
        for mins in [2, 5, 15, 30] {
            let subItem = NSMenuItem(
                title: "\(mins)m",
                action: #selector(handleSelectRefreshInterval(_:)),
                keyEquivalent: ""
            )
            subItem.target = self
            subItem.tag = mins
            subItem.isEnabled = true
            subItem.state = (store.settings.refreshIntervalMinutes == mins) ? .on : .off
            refreshSubmenu.addItem(subItem)
        }
        refreshItem.submenu = refreshSubmenu
        menu.addItem(refreshItem)

        appendUpdateMenuItem()

        menu.addItem(.separator())

        // 4. Quit Item
        let quitItem = NSMenuItem(
            title: "Quit Quota",
            action: #selector(handleQuit(_:)),
            keyEquivalent: ""
        )
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }

    private func appendQuotaRows(for snap: ProviderSnapshot, now: Date) {
        switch snap.status {
        case .idle, .loading:
            let loadingItem = NSMenuItem(
                title: "Loading \(snap.provider.displayName) usage…",
                action: nil,
                keyEquivalent: ""
            )
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)

        case .ready:
            if snap.windows.isEmpty {
                let emptyItem = NSMenuItem(title: "No active subscription limits", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                menu.addItem(emptyItem)
            } else {
                var currentGroup: String? = nil
                for window in snap.windows {
                    if let group = window.group, !group.isEmpty, group != currentGroup {
                        currentGroup = group
                        menu.addItem(.sectionHeader(title: group.uppercased()))
                    }
                    let rowItem = NSMenuItem()
                    rowItem.isEnabled = false
                    rowItem.view = QuotaWindowMenuItemView(window: window, now: now)
                    menu.addItem(rowItem)
                }
            }

            if let warning = snap.refreshWarning {
                appendWarningItems(for: snap, message: warning)
            }

        case .cliMissing(let hint):
            appendWarningItems(for: snap, message: hint)

        case .needsAuth(let message):
            appendWarningItems(for: snap, message: message)

        case .error:
            appendWarningItems(
                for: snap,
                message: "Refresh failed (auth may be outdated or temporary error)."
            )
        }
    }

    private func appendWarningItems(for snap: ProviderSnapshot, message: String) {
        let warnItem = NSMenuItem(title: "⚠ \(message)", action: nil, keyEquivalent: "")
        warnItem.isEnabled = false
        menu.addItem(warnItem)

        let actionTitle: String
        if snap.provider == .codex {
            actionTitle = "Open ChatGPT.app"
        } else if case .cliMissing = snap.status {
            actionTitle = "Install agy CLI"
        } else {
            actionTitle = "Sign in via Terminal"
        }

        let actionItem = NSMenuItem(
            title: actionTitle,
            action: #selector(handleProviderPrimaryAction(_:)),
            keyEquivalent: ""
        )
        actionItem.target = self
        actionItem.representedObject = snap.provider.rawValue
        actionItem.isEnabled = true
        menu.addItem(actionItem)
    }

    private var statusHeaderTitle: String {
        let dates = ProviderID.allCases.compactMap { store.snapshot(for: $0).updatedAt }
        guard let latest = dates.max() else {
            return "Quota · Loading…"
        }
        if store.isRefreshing {
            return "Quota · Updating…"
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(latest)))
        if elapsed < 15 {
            return "Quota · Updated just now"
        } else if elapsed < 60 {
            return "Quota · Updated \(elapsed)s ago"
        } else {
            return "Quota · Updated \(elapsed / 60)m ago"
        }
    }

    // MARK: - Native NSMenu Actions

    @objc private func handleOpenDashboard(_ sender: NSMenuItem) {
        if dashboardWindowController == nil {
            dashboardWindowController = DashboardWindowController(store: store)
        }
        dashboardWindowController?.showDashboard()
    }

    @objc private func handleSelectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        store.settings.selectedProvider = provider
    }

    @objc private func handleToggleWeeklyIndicator(_ sender: NSMenuItem) {
        store.settings.showWeeklyIndicator.toggle()
    }

    @objc private func handleSelectRefreshInterval(_ sender: NSMenuItem) {
        let mins = sender.tag
        if mins > 0 {
            store.settings.refreshIntervalMinutes = mins
        }
    }

    @objc private func handleProviderPrimaryAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        switch provider {
        case .codex:
            store.openChatGPTApp()
        case .antigravity:
            let snap = store.snapshot(for: .antigravity)
            if case .cliMissing = snap.status {
                store.openTerminalToInstallAgy()
            } else {
                store.openAgyAppOrLogin()
            }
        }
    }

    @objc private func handleQuit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - In-App Update Menu & Alerts

    private func appendUpdateMenuItem() {
        switch store.updateState {
        case .updateAvailable(let release):
            let item = NSMenuItem(
                title: "Update to v\(release.version)",
                action: #selector(handleInstallUpdate(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.badge = .updates(count: 1)
            menu.addItem(item)

        case .updating(let version):
            let item = NSMenuItem(title: "Updating to v\(version)…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

        case .checking:
            let item = NSMenuItem(title: "Checking for Updates…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

        case .upToDate(let version):
            let item = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(handleCheckForUpdates(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.badge = NSMenuItemBadge(string: "v\(version)")
            menu.addItem(item)

        case .idle, .failed:
            let item = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(handleCheckForUpdates(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }
    }

    @objc private func handleCheckForUpdates(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.store.checkForUpdates(userInitiated: true)
            switch result {
            case .updateAvailable(let release):
                self.promptToInstallUpdate(release)
            case .upToDate(let version):
                self.presentSimpleAlert(
                    title: "You’re Up to Date",
                    informativeText: "Quota v\(version) is currently the latest version available."
                )
            case .failed(let message):
                self.presentSimpleAlert(
                    title: "Could Not Check for Updates",
                    informativeText: message
                )
            case .idle, .checking, .updating:
                break
            }
        }
    }

    @objc private func handleInstallUpdate(_ sender: NSMenuItem) {
        guard case .updateAvailable(let release) = store.updateState else { return }
        triggerSelfUpdate(release)
    }

    private func promptToInstallUpdate(_ release: ReleaseAssetInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Quota v\(release.version) is Available"
        alert.informativeText = "You are currently running v\(UpdateService.currentAppVersion). Would you like to download, install, and relaunch Quota automatically?"
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            triggerSelfUpdate(release)
        }
    }

    private func triggerSelfUpdate(_ release: ReleaseAssetInfo) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.installAvailableUpdate(release)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.icon = NSApp.applicationIconImage
                alert.messageText = "Automatic Update Failed"
                alert.informativeText = "\(error.localizedDescription)\n\nYou can also upgrade via `brew upgrade --cask quota` or download from GitHub Releases."
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.releasePageURL)
                }
            }
        }
    }

    private func presentSimpleAlert(title: String, informativeText: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}

// MARK: - Colored Weekly Watermark Dot Overlay

/// Non-interactive overlay inside `NSStatusBarButton` that renders the vibrant Green / Yellow / Red
/// weekly watermark dot inside `BeerMugIcon`'s cutout halo while keeping the beer mug `isTemplate = true`.
private final class WeeklyDotOverlayView: NSView {
    var watermark: QuotaAlertLevel? {
        didSet {
            if oldValue != watermark {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let watermark else { return }

        let iconOriginX = round((bounds.width - 18.0) * 0.5)
        let iconOriginY = round((bounds.height - 18.0) * 0.5)
        let diameter = BeerMugIcon.dotDiameter
        let dotRect = NSRect(
            x: iconOriginX + BeerMugIcon.dotCenter.x - diameter * 0.5,
            y: iconOriginY + BeerMugIcon.dotCenter.y - diameter * 0.5,
            width: diameter,
            height: diameter
        )

        let dotColor: NSColor
        switch watermark {
        case .normal:
            dotColor = .systemGreen
        case .warning:
            dotColor = .systemYellow
        case .critical:
            dotColor = .systemRed
        }

        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

// MARK: - Status Button Hover Overlay

private final class HoverTrackingOverlayView: NSView {
    private let onMouseEntered: () -> Void
    private let onMouseExited: () -> Void
    private var trackingAreaRef: NSTrackingArea?

    init(onMouseEntered: @escaping () -> Void, onMouseExited: @escaping () -> Void) {
        self.onMouseEntered = onMouseEntered
        self.onMouseExited = onMouseExited
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited()
    }
}
