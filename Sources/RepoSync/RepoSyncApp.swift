import AppKit
import Combine
import SwiftUI

@main
struct RepoSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Headless.runIfRequested()
        Headless.renderPreviewIfRequested()
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// A popover rather than MenuBarExtra: MenuBarExtra's window doesn't resize when the panel switches panes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let onboardingDismissedKey = "onboardingDismissed"

    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconUpdates: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let hosting = NSHostingController(rootView: MenuPanel().environmentObject(model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        PanelControl.close = { [weak self] in self?.popover.performClose(nil) }

        updateIcon()
        iconUpdates = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }

        showOnboardingIfNeeded()
    }

    // Someone with no folder sees onboarding until they finish it; existing users are shown a failing checklist once.
    private func showOnboardingIfNeeded() {
        guard model.folderPath != nil else {
            OnboardingWindow.show(model: model, start: .welcome)
            return
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.onboardingDismissedKey) else { return }
        Task {
            let report = await model.checkSetup()
            guard let step = OnboardingModel.initialStep(folderConfigured: true, setupReady: report.isReady) else { return }
            defaults.set(true, forKey: Self.onboardingDismissedKey)
            OnboardingWindow.show(model: model, start: step)
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.pane = .main
        model.refreshLive()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateIcon() {
        let badge: NSColor?
        if model.hasFailure {
            badge = .systemRed
        } else if !model.needsAttention.isEmpty || model.hasPendingDeletions || model.setupProblem != nil {
            badge = .systemOrange
        } else {
            badge = nil
        }
        statusItem.button?.image = MenuBarIcon.image(badge: badge)
    }
}

@MainActor
enum PanelControl {
    static var close: () -> Void = {}
}

enum MenuBarIcon {
    static func image(badge: NSColor?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "square.stack.3d.down.right", accessibilityDescription: "Repo Sync")?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }
        guard let badge else {
            symbol.isTemplate = true
            return symbol
        }

        let size = NSSize(width: symbol.size.width + 3, height: max(symbol.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolRect = NSRect(
                x: 0, y: (rect.height - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            )
            symbol.draw(in: symbolRect)
            NSColor.labelColor.set()
            symbolRect.fill(using: .sourceAtop)

            let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
            badge.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Repo Sync, needs attention"
        return image
    }
}
