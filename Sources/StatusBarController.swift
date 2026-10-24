import AppKit
import Combine
import SwiftUI

/// AppKit status item so we can pin placement via `autosaveName` + preferred position.
///
/// `NSStatusItem Preferred Position` is effectively a screen X hint:
/// **smaller → further left** in the status-item strip (away from the clock).
/// We pin to the leading edge of that strip — the leftmost status item.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    static let autosaveName = "GrokBar"

    private let model: UsageViewModel
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var escKeyMonitor: Any?
    /// When the popover last closed. A `.transient` popover closes itself on the same
    /// mouse-down that hits the status item; without this the click would reopen it.
    private var lastPopoverCloseAt: Date?
    private let reopenGuard: TimeInterval = 0.3

    init(model: UsageViewModel) {
        self.model = model
        super.init()
    }

    func install() {
        // Write before creating the item so the bar picks up the placement hint.
        Self.preferLeftmostStatusItem()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)

        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageHugsTitle = true
            button.setButtonType(.toggle)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Act on mouse-down (like system menu extras) so the transient auto-close
            // and our click land within the reopen guard window.
            button.sendAction(on: [.leftMouseDown])
            button.toolTip = model.menuBarAccessibilityLabel
            button.appearsDisabled = false
        }

        statusItem = item
        bindModel()
        updateButton()

        // Re-assert after insert (some OS versions snapshot prefs at creation only).
        DispatchQueue.main.async {
            Self.preferLeftmostStatusItem()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.preferLeftmostStatusItem()
        }
    }

    /// Sit at the leading (left) edge of the status-item strip — first icon
    /// on the left of Wi‑Fi / battery / clock, as far from the date as possible.
    static func preferLeftmostStatusItem() {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        // 0 sorts before other third-party / system extras that use larger X hints.
        UserDefaults.standard.set(Float(0), forKey: key)
        UserDefaults.standard.synchronize()
    }

    private func bindModel() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButton()
            }
            .store(in: &cancellables)

        // Also tick on published clock so countdown stays live.
        model.$clockTick
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButton()
            }
            .store(in: &cancellables)

        // "Show days left" applies immediately, whether toggled in the popover or via `defaults write`.
        model.$showDaysLeft
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButton()
            }
            .store(in: &cancellables)

        model.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButton()
            }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.toolTip = model.menuBarAccessibilityLabel
        button.image = MenuBarRenderer.image(model: model)
        button.imagePosition = .imageOnly
    }

    /// Click toggles: open → close, closed → open.
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            closePopover()
        } else if let closed = lastPopoverCloseAt, Date().timeIntervalSince(closed) < reopenGuard {
            // The transient popover already closed itself for this very click.
            lastPopoverCloseAt = nil
        } else {
            showPopover(relativeTo: button)
        }
        button.state = (popover?.isShown == true) ? .on : .off
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        model.panelDidOpen()
        // Accessory apps aren't active by default; activate so the first click
        // in the popover lands on its buttons instead of just focusing it.
        NSApp.activate(ignoringOtherApps: true)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuContentView(model: model)
                .environment(\.colorScheme, colorSchemeForMenuBar())
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.state = .on

        // Dismiss when clicking in another app (the transient behavior covers our own windows).
        localEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
        // Esc closes it.
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.closePopover() }
            return nil
        }
    }

    private func closePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)  // → popoverDidClose does the cleanup
        } else {
            popoverCleanup()
        }
    }

    nonisolated func popoverWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { lastPopoverCloseAt = Date() }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            lastPopoverCloseAt = Date()
            popoverCleanup()
        }
    }

    private func popoverCleanup() {
        popover = nil
        statusItem?.button?.state = .off
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let escKeyMonitor {
            NSEvent.removeMonitor(escKeyMonitor)
            self.escKeyMonitor = nil
        }
    }

    private func colorSchemeForMenuBar() -> ColorScheme {
        let appearance = statusItem?.button?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .dark : .light
    }
}
