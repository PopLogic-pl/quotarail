import AppKit
import SwiftUI
import Combine
import Darwin

@main
struct QuotaRail {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--capture-claude", let id = UUID(uuidString: args[2]) {
            if let data = try? captureInput(),
               (try? Storage.captureClaude(id, data: data)) != nil {
                print(tr("QuotaRail · Reading saved"))
            }
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MenuApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func captureInput() throws -> Data {
        var result = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= 1_048_576 else { throw ReadError.noQuota }
        }
        return result
    }
}

@MainActor
private final class MenuApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store()
    private let popover = NSPopover()
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var updates: AnyCancellable?
    private var timer: Timer?
    private var nextRefresh = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.autosaveName = "quotarail"
        let panel = Panel(store: store) { NSApp.terminate(nil) }
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.contentSize = NSSize(width: PanelLayout.width, height: PanelLayout.height)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.animates = false
        if let button = status.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .noImage
        }
        updates = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
        updateTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        if !UserDefaults.standard.bool(forKey: "openedFirstRun") {
            UserDefaults.standard.set(true, forKey: "openedFirstRun")
            togglePanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        NSApp.modalWindow == nil
    }

    @objc private func togglePanel() {
        guard let button = status.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.tick()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func tick() {
        store.tick()
        guard !store.accounts.isEmpty, Date() >= nextRefresh else { return }
        nextRefresh = Date().addingTimeInterval(180)
        Task { await store.refresh() }
    }

    private func updateTitle() {
        guard let button = status.button else { return }
        let title = NSMutableAttributedString(string: "")
        let small = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let figures = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let bracket: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.systemRed
        ]
        title.append(NSAttributedString(string: "⟦ ", attributes: bracket))
        var descriptions: [String] = []
        let accounts = store.pinned
        if accounts.isEmpty {
            title.append(NSAttributedString(string: tr("Agents"), attributes: [.font: small]))
        }
        for (index, account) in accounts.enumerated() {
            let quotas = store.freshQuotas(account)
            let value = MenuBarReadout.value(for: account, quotas: quotas)
            if index > 0 {
                title.append(NSAttributedString(string: " · ", attributes: [
                    .font: small, .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            title.append(NSAttributedString(string: account.abbreviation + " ", attributes: [.font: small]))
            title.append(NSAttributedString(string: value, attributes: [.font: figures]))
            let identity = account.provider.name + ", " + account.name
            let detail = quotas.map { tr("%@: %@ remaining", $0.title, $0.value) }.joined(separator: ", ")
            descriptions.append(identity + (detail.isEmpty ? ", " + (store.errors[account.id] ?? tr("No reading")) : ", " + detail))
        }
        title.append(NSAttributedString(string: " ⟧", attributes: bracket))
        if !button.attributedTitle.isEqual(to: title) {
            button.attributedTitle = title
        }
        button.toolTip = descriptions.isEmpty ? tr("Agent limits") : descriptions.joined(separator: "\n")
        button.setAccessibilityLabel(descriptions.isEmpty ? tr("Agent limits") : descriptions.joined(separator: ". "))
    }
}
