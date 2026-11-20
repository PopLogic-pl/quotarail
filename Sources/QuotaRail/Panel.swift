import SwiftUI
import AppKit


// Use the property wrapper with command-line SDKs that lack the SwiftUI macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Palette {
    static let background = Color(red: 0.060, green: 0.076, blue: 0.089)
    static let surface = Color(red: 0.094, green: 0.114, blue: 0.131)
    static let surfaceHover = Color(red: 0.129, green: 0.155, blue: 0.174)
    static let border = Color(red: 0.178, green: 0.207, blue: 0.231)
    static let text = Color(red: 0.940, green: 0.962, blue: 0.975)
    static let secondary = Color(red: 0.644, green: 0.698, blue: 0.742)
    static let mint = Color(red: 0.495, green: 0.904, blue: 0.781)
    static let gold = Color(red: 0.988, green: 0.766, blue: 0.420)
    static let pink = Color(red: 0.992, green: 0.550, blue: 0.570)

    static func quota(_ value: Double) -> Color {
        if value <= 20 { return pink }
        if value <= 40 { return gold }
        return mint
    }

    static func provider(_ provider: Provider) -> Color {
        switch provider {
        case .codex: return mint
        case .claude: return Color(red: 1, green: 0.686, blue: 0.520)
        case .cursor: return Color(red: 0.770, green: 0.823, blue: 0.917)
        case .antigravity: return Color(red: 0.713, green: 0.650, blue: 0.990)
        case .copilot: return Color(red: 0.641, green: 0.702, blue: 0.990)
        }
    }
}

enum PanelLayout {
    static let width: CGFloat = 438
    static let height: CGFloat = 560
    static let inset: CGFloat = 22
}

struct Panel: View {
    @ObservedObject var store: Store
    @ViewState var page: Page = .overview
    let quit: () -> Void

    enum Page {
        case overview, providers, edit(Account, Bool)
    }

    var body: some View {
        Group {
            switch page {
            case .overview: overview
            case .providers: providerPicker
            case .edit(let account, let isNew):
                AccountEditor(store: store, draft: account, isNew: isNew,
                              cancel: { page = isNew ? .providers : .overview },
                              done: { page = .overview })
                    .id(account.id)
            }
        }
        .frame(width: PanelLayout.width, height: PanelLayout.height)
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .environment(\.colorScheme, .dark)
    }

    private var overview: some View {
        VStack(spacing: 0) {
            header
            if !store.accounts.isEmpty {
                HStack(spacing: 7) {
                    ForEach(AccountFilter.allCases, id: \.self) { filter in
                        let selected = store.filter == filter
                        Button { store.filter = filter } label: {
                            Text(filter.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selected ? Palette.text : Palette.secondary)
                                .padding(.horizontal, 11)
                                .frame(height: 27)
                                .background(selected ? Palette.surfaceHover : Color.clear, in: Capsule())
                                .overlay(Capsule().strokeBorder(selected ? Palette.border : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Spacer()
                    Text(tr("REMAINING"))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Palette.secondary)
                        .padding(.trailing, 3)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, PanelLayout.inset)
                .padding(.bottom, 13)
            }

            if store.visible.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(store.visible) { account in
                            AccountCard(account: account, quotas: store.quotas(account),
                                        reading: store.readings[account.id], error: store.errors[account.id],
                                        pending: store.pending.contains(account.id), now: store.now) {
                                page = .edit(account, false)
                            }
                        }
                    }
                    .padding(.horizontal, PanelLayout.inset)
                    .padding(.bottom, 13)
                }
                .frame(maxHeight: .infinity)
            }

            HStack(spacing: 9) {
                Circle()
                    .fill(store.refreshing ? Palette.gold : (store.pinned.contains { store.freshMinimum($0) != nil } ? Palette.mint : Palette.secondary))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(refreshSummary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                Spacer()
                IconButton(symbol: "arrow.clockwise", title: tr("Refresh now")) {
                    Task { await store.refresh() }
                }
                .disabled(store.refreshing || store.accounts.isEmpty)
                IconButton(symbol: "power", title: tr("Quit QuotaRail"), action: quit)
            }
            .padding(.horizontal, PanelLayout.inset)
            .frame(height: 49)
            .overlay(alignment: .top) { Divider().overlay(Palette.border) }
        }
    }

    private var refreshSummary: String {
        if store.refreshing { return tr("Refreshing…") }
        if let date = store.lastRefresh {
            return tr("Checked · %@", PanelDate.observation(date, now: store.now))
        }
        return tr("No readings yet")
    }

    private var empty: some View {
        VStack(spacing: 11) {
            Image(systemName: store.filter == .pinned ? "pin" : "percent")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.mint)
                .frame(width: 50, height: 50)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            Text(store.filter == .pinned ? tr("No pinned accounts") : tr("Add your first account"))
                .font(.system(size: 16, weight: .semibold))
            Text(store.filter == .pinned ? tr("Pin an account in its settings.") : tr("Choose an agent and set its quota source."))
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            if store.filter == .all {
                Button(tr("Add account")) { page = .providers }
                    .buttonStyle(FilledButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(tr("Agent limits")).font(.system(size: 27, weight: .semibold))
                .tracking(-0.65)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if !store.accounts.isEmpty {
                Button { page = .providers } label: {
                    Label(tr("Add account"), systemImage: "plus")
                }
                .buttonStyle(FilledButtonStyle())
            }
        }
        .padding(.horizontal, PanelLayout.inset)
        .padding(.top, 23)
        .padding(.bottom, 20)
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: tr("Add account"), subtitle: tr("Choose a provider to track its quotas."),
                       back: { page = .overview })
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(Provider.allCases) { provider in
                        let count = store.accounts.filter { $0.provider == provider }.count
                        let full = provider.maxAccounts.map { count >= $0 } ?? false
                        Button {
                            page = .edit(store.draft(for: provider), true)
                        } label: {
                            HStack(spacing: 11) {
                                ProviderIcon(provider: provider)
                                Text(provider.name).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                if count > 0 {
                                    Text(String(count))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Palette.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Palette.secondary)
                            }
                            .padding(9)
                            .padding(.trailing, 4)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(full)
                        .opacity(full ? 0.5 : 1)
                    }
                }
                .padding(.bottom, 9)
            }
        }
        .padding(.horizontal, PanelLayout.inset)
        .padding(.top, 21)
    }
}

private struct AccountCard: View {
    let account: Account
    let quotas: [Quota]
    let reading: Reading?
    let error: String?
    let pending: Bool
    let now: Date
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                ProviderIcon(provider: account.provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.provider.name)
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(account.name)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if account.pinned {
                    Text(account.abbreviation)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Palette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel(tr("In the menu bar: %@", account.abbreviation))
                }
                IconButton(symbol: "ellipsis", title: tr("Settings · %@ · %@", account.provider.name, account.name), action: edit)
            }

            if !quotas.isEmpty {
                Divider().overlay(Palette.border)
                ForEach(quotas) { quota in
                    HStack(spacing: 8) {
                        Text(quota.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .help(quota.title)
                        Spacer(minLength: 2)
                        if let reset = quota.reset {
                            Text(PanelDate.reset(reset, now: now))
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .accessibilityLabel(tr("Resets %@", PanelDate.reset(reset, now: now)))
                        }
                        Text(quota.value)
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .tracking(-0.9)
                            .foregroundStyle(error == nil ? Palette.quota(quota.remaining) : Palette.secondary)
                            .frame(minWidth: 65, alignment: .trailing)
                            .accessibilityLabel(tr("%@ remaining", quota.value))
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if let error {
                status(quotas.isEmpty ? error : tr("Last reading · %@", error), icon: "info.circle")
            } else if quotas.isEmpty {
                status(pending ? tr("Reading limits…") : tr("Waiting for first reading"), icon: "clock")
            } else if account.provider == .claude, let reading {
                status(tr("Reading · %@", PanelDate.observation(reading.observed, now: now)), icon: "terminal")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
    }

    private func status(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10))
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ProviderIcon: View {
    let provider: Provider

    var body: some View {
        let color = Palette.provider(provider)
        Image(systemName: provider.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 31, height: 31)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.20)))
            .accessibilityHidden(true)
    }
}

struct IconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovered ? Palette.text : Palette.secondary)
                .frame(width: 27, height: 27)
                .background(hovered ? Palette.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Palette.background)
            .padding(.horizontal, 12)
            .frame(height: 31)
            .background(Palette.mint.opacity(configuration.isPressed ? 0.77 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    let back: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconButton(symbol: "chevron.left", title: tr("Back"), action: back)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
        }
    }
}

private enum PanelDate {
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute(.twoDigits).locale(appLocale))
    }

    static func observation(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? time(date) : day(date) + ", " + time(date)
    }

    static func reset(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return tr("Today %@", time(date)) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return tr("Tomorrow %@", time(date)) }
        return day(date) + " · " + time(date)
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(appLocale))
    }
}
