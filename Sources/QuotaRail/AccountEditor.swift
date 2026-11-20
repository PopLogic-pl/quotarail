import SwiftUI
import AppKit

struct AccountEditor: View {
    @ObservedObject var store: Store
    @ViewState var draft: Account
    let isNew: Bool
    let cancel: () -> Void
    let done: () -> Void

    @ViewState private var token = ""
    @ViewState private var tokenStored = false
    @ViewState private var forgetToken = false
    @ViewState private var error: String?
    @ViewState private var confirmRemoval = false
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: isNew ? tr("New account") : tr("Account settings"),
                       subtitle: draft.provider.name, back: cancel)
                .padding(.vertical, 18)
                .padding(.horizontal, PanelLayout.inset)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 10) {
                        field(tr("Account name")) { TextField(tr("e.g. Personal"), text: $draft.name) }
                        field(tr("Menu bar label")) { TextField(tr("e.g. Cx"), text: $draft.abbreviation) }
                            .frame(width: 105)
                    }

                    Toggle(tr("Show this account in the menu bar"), isOn: $draft.pinned)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Palette.mint)
                        .font(.system(size: 12, weight: .medium))

                    Divider().overlay(Palette.border)
                    Text(tr("Quota source"))
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    if let title = draft.provider.pathTitle {
                        field(title) {
                            HStack(spacing: 6) {
                                TextField(draft.provider.defaultPath.isEmpty ? tr("Default profile") : draft.provider.defaultPath,
                                          text: $draft.path)
                                IconButton(symbol: "folder", title: tr("Choose in Finder"), action: choosePath)
                            }
                        }
                    }

                    if let title = draft.provider.tokenTitle {
                        field(title) {
                            SecureField(tokenStored && !forgetToken ? tr("Token saved in Keychain") : tr("Paste a token"), text: $token)
                        }
                        if tokenStored {
                            Toggle(tr("Remove saved token"), isOn: $forgetToken)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11))
                        }
                    }

                    if draft.provider == .claude {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(statusLineConfiguration, forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? tr("Configuration copied") : tr("Copy Claude Code configuration"),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(FilledButtonStyle())
                        Text(tr("Add the statusLine property to the selected profile’s settings.json."))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondary)
                    }
                    Text(draft.provider.help)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.pink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, PanelLayout.inset)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 13) {
                if !isNew {
                    Button(tr("Remove account"), role: .destructive) { confirmRemoval = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.pink)
                }
                Spacer()
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                Button(isNew ? tr("Add account") : tr("Save"), action: save)
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PanelLayout.inset)
            .frame(height: 53)
            .overlay(alignment: .top) { Divider().overlay(Palette.border) }
        }
        .onAppear {
            tokenStored = store.tokenExists(draft)
        }
        .confirmationDialog(tr("Remove the account “%@”?", draft.name), isPresented: $confirmRemoval) {
            Button(tr("Remove account"), role: .destructive) {
                do {
                    try store.remove(draft)
                    done()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func field<Field: View>(_ title: String, @ViewBuilder input: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondary)
            input()
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border).allowsHitTesting(false))
                .accessibilityLabel(title)
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = draft.provider != .cursor
        panel.canChooseFiles = draft.provider == .cursor
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !draft.path.isEmpty {
            let location = URL(fileURLWithPath: draft.path.expanded)
            panel.directoryURL = panel.canChooseDirectories ? location : location.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url { draft.path = url.path }
    }

    private func save() {
        do {
            try store.save(draft, token: token, forgetToken: forgetToken)
            if draft.pinned == false && store.filter == .pinned { store.filter = .all }
            done()
            Task { await store.refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var statusLineConfiguration: String {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let command = executable.shellQuoted + " --capture-claude " + draft.id.uuidString
        let settings = ["statusLine": ["type": "command", "command": command]]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
