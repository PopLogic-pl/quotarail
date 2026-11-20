import AppKit
import SwiftUI

// Use the property wrapper when building with Command Line Tools alone.
private typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct QuotaRail {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let menu = RailMenu()
        application.delegate = menu
        withExtendedLifetime(menu) { application.run() }
    }
}

private struct RailItem: Identifiable {
    let id: String
    let name: String
    let example: String

    static let items = [
        RailItem(id: "CC", name: "Claude Code", example: "91/99%"),
        RailItem(id: "Cx", name: "OpenAI Codex", example: "63%"),
        RailItem(id: "Cr", name: "Cursor", example: "87/48%"),
        RailItem(id: "Ag", name: "Antigravity", example: "100/96%"),
        RailItem(id: "CW", name: "Claude Code · drugie konto", example: "72/18%"),
        RailItem(id: "Cop", name: "GitHub Copilot", example: "94%")
    ]

    func value(examples: Bool) -> String { examples ? example : "–" }
}

@MainActor
private final class RailMenu: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.autosaveName = "quotarail"
        status.button?.target = self
        status.button?.action = #selector(togglePanel)

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let controller = NSHostingController(rootView: RailPanel { [weak self] examples in
            self?.updateReadout(examples: examples)
        })
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        updateReadout(examples: false)
    }

    @objc private func togglePanel() {
        guard let button = status.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }

    private func updateReadout(examples: Bool) {
        let bracket: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 14, weight: .bold)
        ]
        let label = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let number = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let title = NSMutableAttributedString(string: "⟦ ", attributes: bracket)

        for (index, item) in RailItem.items.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " · ", attributes: [
                    .font: label, .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            title.append(NSAttributedString(string: item.id + " ", attributes: [.font: label]))
            title.append(NSAttributedString(string: item.value(examples: examples), attributes: [.font: number]))
        }
        title.append(NSAttributedString(string: " ⟧", attributes: bracket))
        status.button?.attributedTitle = title
        status.button?.setAccessibilityLabel(examples ? "QuotaRail, dane przykładowe" : "QuotaRail, pusty podgląd")
        status.button?.toolTip = "QuotaRail · podgląd paska limitów"
    }
}

private struct RailPanel: View {
    @ViewState private var examples = false
    let updateReadout: (Bool) -> Void

    private let background = Color(red: 0.060, green: 0.076, blue: 0.089)
    private let surface = Color(red: 0.094, green: 0.114, blue: 0.131)
    private let mint = Color(red: 0.495, green: 0.904, blue: 0.781)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("QuotaRail")
                    .font(.system(size: 25, weight: .bold))
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zakończ QuotaRail")
                .help("Zakończ QuotaRail")
            }

            Toggle("Pokaż przykładowe limity", isOn: $examples)
                .toggleStyle(.switch)
                .tint(mint)
                .onChange(of: examples, perform: updateReadout)

            VStack(spacing: 8) {
                ForEach(RailItem.items) { item in
                    HStack(spacing: 11) {
                        Text(item.id)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .leading)
                        Text(item.name)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(item.value(examples: examples))
                            .font(.system(size: 18, weight: .semibold).monospacedDigit())
                            .foregroundStyle(examples ? mint : Color.secondary)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background(surface, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(21)
        .frame(width: 390)
        .background(background)
        .environment(\.colorScheme, .dark)
    }
}
