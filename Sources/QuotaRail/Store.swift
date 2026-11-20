import Foundation
import Combine

@MainActor
final class Store: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var readings: [UUID: Reading] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var pending: Set<UUID> = []
    @Published private(set) var now = Date()
    @Published private(set) var lastRefresh: Date?
    @Published var filter: AccountFilter = .all
    private let defaults: UserDefaults
    private var rerun = false
    private var revisions: [UUID: UUID] = [:]
    private let defaultsKey = "trackedAccounts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([SavedAccount].self, from: data) {
            accounts = saved.compactMap(\.value)
            if accounts.count != saved.count { persist() }
        }
    }

    var pinned: [Account] { MenuBarReadout.ordered(accounts.filter(\.pinned)) }
    var visible: [Account] { filter == .pinned ? pinned : MenuBarReadout.ordered(accounts) }
    var refreshing: Bool { !pending.isEmpty }

    func quotas(_ account: Account) -> [Quota] {
        readings[account.id]?.active(at: now) ?? []
    }

    func freshMinimum(_ account: Account) -> Quota? {
        freshQuotas(account).min { $0.remaining < $1.remaining }
    }

    func freshQuotas(_ account: Account) -> [Quota] {
        errors[account.id] == nil ? quotas(account) : []
    }

    func tick() { now = Date() }

    func refresh() async {
        tick()
        guard !accounts.isEmpty else { return }
        if !pending.isEmpty {
            rerun = true
            return
        }
        repeat {
            rerun = false
            let batch = accounts.map { ($0, revisions[$0.id]) }
            pending = Set(batch.map { $0.0.id })
            await withTaskGroup(of: (UUID, UUID?, Result<Reading, Error>).self) { group in
                for (account, revision) in batch {
                    group.addTask {
                        do { return (account.id, revision, .success(try await Usage.fetch(account))) }
                        catch { return (account.id, revision, .failure(error)) }
                    }
                }
                for await (id, revision, result) in group {
                    if accounts.contains(where: { $0.id == id }), revisions[id] == revision {
                        switch result {
                        case .success(let reading):
                            readings[id] = reading
                            errors.removeValue(forKey: id)
                        case .failure(let error):
                            errors[id] = message(for: error)
                        }
                    }
                    // Keep the final item pending until the entire batch has returned.
                    if pending.count > 1 { pending.remove(id) }
                }
            }
            pending = []
            lastRefresh = accounts.isEmpty ? nil : Date()
            tick()
        } while rerun && !accounts.isEmpty
    }

    func save(_ draft: Account, token: String, forgetToken: Bool) throws {
        var account = draft
        account.name = account.name.trimmed
        account.abbreviation = account.abbreviation.trimmed
        account.path = account.path.trimmed
        guard !account.name.isEmpty, account.name.count <= 40 else {
            throw ReadError.setup(tr("Enter an account name between 1 and 40 characters."))
        }
        guard (1...6).contains(account.abbreviation.count),
              account.abbreviation.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw ReadError.setup(tr("Use 1 to 6 letters, digits, or hyphens for the menu bar label."))
        }
        let other = accounts.filter { $0.id != account.id && $0.provider == account.provider }
        if let max = account.provider.maxAccounts, other.count >= max {
            throw ReadError.setup(tr("This provider supports up to two accounts."))
        }
        guard !account.pinned || !pinned.contains(where: { $0.id != account.id &&
            $0.abbreviation.caseInsensitiveCompare(account.abbreviation) == .orderedSame
        }) else { throw ReadError.setup(tr("Choose a different menu bar label for each pinned account.")) }
        let old = accounts.first { $0.id == account.id }
        let newToken = token.trimmed
        if !newToken.isEmpty && newToken.rangeOfCharacter(from: .controlCharacters) != nil {
            throw ReadError.setup(tr("Remove control characters from the token."))
        }
        let storedToken = account.provider.tokenTitle == nil || (!newToken.isEmpty || forgetToken)
            ? nil : try Storage.token(account.id)
        let effectiveToken = !newToken.isEmpty ? newToken : storedToken
        if let effectiveToken, let sibling = other.first,
           account.provider.tokenTitle != nil, try Storage.token(sibling.id) == effectiveToken {
            throw ReadError.setup(tr("Use a separate token for each account with this provider."))
        }
        if [.codex, .antigravity].contains(account.provider), account.path.isEmpty {
            throw ReadError.setup(tr("Choose the profile folder for this account."))
        }
        if [.codex, .claude, .antigravity, .cursor].contains(account.provider), effectiveToken == nil {
            let path = account.provider == .claude ? canonicalClaude(account.path) : canonical(account.path)
            for sibling in other {
                let siblingPath = account.provider == .claude ? canonicalClaude(sibling.path) : canonical(sibling.path)
                guard path == siblingPath else { continue }
                let siblingToken = account.provider == .cursor ? try Storage.token(sibling.id) : nil
                if siblingToken == nil { throw ReadError.setup(tr("Choose a separate source for each account.")) }
            }
        }
        if account.provider == .copilot, effectiveToken == nil, let sibling = other.first,
           try Storage.token(sibling.id) == nil {
            throw ReadError.setup(tr("Only one account can use the default Copilot or GitHub CLI sign-in."))
        }
        if account.provider.tokenTitle != nil {
            if !newToken.isEmpty { try Storage.setToken(newToken, id: account.id) }
            else if forgetToken { try Storage.deleteToken(account.id) }
        }
        if old == nil || old?.path != account.path || !newToken.isEmpty || forgetToken {
            revisions[account.id] = UUID()
            readings.removeValue(forKey: account.id)
            errors.removeValue(forKey: account.id)
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        else { accounts.append(account) }
        persist()
    }

    func tokenExists(_ account: Account) -> Bool {
        account.provider.tokenTitle != nil &&
            ((try? Storage.token(account.id)) != nil)
    }

    func draft(for provider: Provider) -> Account {
        let aliases = Set(accounts.map { $0.abbreviation.lowercased() })
        var number = accounts.filter { $0.provider == provider }.count + 1
        var account = Account(provider: provider, number: number)
        while aliases.contains(account.abbreviation.lowercased()) {
            number += 1
            account = Account(provider: provider, number: number)
        }
        return account
    }

    func remove(_ account: Account) throws {
        if account.provider.tokenTitle != nil { try Storage.deleteToken(account.id) }
        if account.provider == .claude {
            let file = Storage.claudeFile(account.id)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        accounts.removeAll { $0.id == account.id }
        if accounts.isEmpty { lastRefresh = nil }
        readings.removeValue(forKey: account.id)
        errors.removeValue(forKey: account.id)
        revisions.removeValue(forKey: account.id)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func canonicalClaude(_ path: String) -> String {
        canonical(path.isEmpty ? "~/.claude" : path)
    }

    private func canonical(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path.expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func message(for error: Error) -> String {
        if let known = error as? ReadError { return known.localizedDescription }
        if let network = error as? URLError {
            return network.code == .timedOut ? tr("The connection timed out.") : tr("Could not connect to the provider.")
        }
        return tr("Could not read the quota.")
    }
}

private struct SavedAccount: Decodable {
    let value: Account?

    init(from decoder: Decoder) {
        value = try? Account(from: decoder)
    }
}

enum AccountFilter: CaseIterable {
    case all, pinned

    var title: String {
        switch self {
        case .all: tr("All accounts")
        case .pinned: tr("Pinned")
        }
    }
}
