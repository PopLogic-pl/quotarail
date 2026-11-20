import Foundation
import LocalAuthentication
import Security

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor, antigravity, copilot

    var id: Self { self }

    var name: String {
        switch self {
        case .codex: "OpenAI Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        }
    }

    var abbreviation: String {
        switch self {
        case .codex: "Cx"
        case .claude: "CC"
        case .cursor: "Cr"
        case .copilot: "Cop"
        case .antigravity: "Ag"
        }
    }

    var symbol: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sun.max"
        case .cursor: "cursorarrow"
        case .copilot: "chevron.left.chevron.right"
        case .antigravity: "triangle.fill"
        }
    }

    var defaultPath: String {
        switch self {
        case .codex: "~/.codex"
        case .antigravity: "~"
        case .cursor, .claude, .copilot: ""
        }
    }

    var tokenTitle: String? {
        switch self {
        case .cursor: tr("Cursor session token (optional)")
        case .copilot: tr("GitHub token (optional for the first account)")
        default: nil
        }
    }

    var pathTitle: String? {
        switch self {
        case .codex: tr("Codex profile folder")
        case .claude: tr("Claude Code profile folder (optional)")
        case .cursor: tr("auth.json or state.vscdb file (optional)")
        case .antigravity: tr("Antigravity profile home folder")
        default: nil
        }
    }

    var help: String {
        switch self {
        case .codex: tr("Choose the signed-in account’s CODEX_HOME folder. Sign in to each additional Codex account in a separate folder.")
        case .claude: tr("Leave the folder blank to use your default Claude Code profile. For another account, choose its CLAUDE_CONFIG_DIR folder, such as ~/.claude-work. The status line can supply limits if the CLI cannot.")
        case .cursor: tr("Leave both fields blank to use your Cursor sign-in. For a second account, choose its own profile file or enter its WorkosCursorSessionToken.")
        case .copilot: tr("Use your Copilot CLI or GitHub CLI (gh) sign-in. You can also provide a token with Copilot access.")
        case .antigravity: tr("Install agy with JSON support for /usage. Sign in to a second profile from its own home folder.")
        }
    }

    var maxAccounts: Int? {
        switch self {
        case .codex, .claude: nil
        case .cursor, .copilot, .antigravity: 2
        }
    }
}

struct Account: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var provider: Provider
    var name: String
    var abbreviation: String
    var pinned = true
    var path: String

    init(provider: Provider, number: Int = 1) {
        self.provider = provider
        name = number == 1 ? tr("Primary") : tr("Account %lld", Int64(number))
        abbreviation = provider.abbreviation + (number == 1 ? "" : String(number))
        path = number == 1 ? provider.defaultPath : ""
    }
}

struct Quota: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let remaining: Double
    let reset: Date?

    init?(id: String, title: String, remaining: Double?, reset: Date? = nil) {
        guard let remaining, remaining.isFinite else { return nil }
        self.id = id
        self.title = title
        self.remaining = max(0, min(100, remaining))
        self.reset = reset
    }

    var value: String {
        if remaining > 0 && remaining < 1 { return "<1%" }
        if remaining > 99 && remaining < 100 { return ">99%" }
        return "\(Int(remaining.rounded()))%"
    }
}

struct Reading: Codable, Equatable, Sendable {
    let quotas: [Quota]
    let observed: Date

    func active(at date: Date) -> [Quota] {
        quotas.filter { $0.reset.map { $0 > date } ?? true }
    }
}

enum ReadError: LocalizedError {
    case setup(String), unavailable(String), http(Int), timeout, noQuota

    var errorDescription: String? {
        switch self {
        case .setup(let message), .unavailable(let message): message
        case .http(401), .http(403): tr("Check your sign-in or token permissions.")
        case .http(429): tr("The provider is rate limiting requests. Try again in a moment.")
        case .http(let status): tr("The provider returned an error (HTTP %lld).", Int64(status))
        case .timeout: tr("The request timed out.")
        case .noQuota: tr("This plan did not return a percentage limit.")
        }
    }
}

enum Storage {
    static let service = "pl.poplogic.quotarail.tokens"
    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/QuotaRail", isDirectory: true)
    }

    static func claudeFile(_ id: UUID) -> URL {
        directory.appendingPathComponent("claude-\(id.uuidString).json")
    }

    static func captureClaude(_ id: UUID, data: Data) throws {
        let reading = try QuotaParsers.claude(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(reading).write(to: claudeFile(id), options: .atomic)
    }

    static func token(_ id: UUID) throws -> String? {
        var query = tokenQuery(id)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = nonInteractiveKeychainContext()
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ReadError.setup(tr("Keychain is unavailable for this account."))
        }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, id: UUID) throws {
        let query = tokenQuery(id)
        let values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw ReadError.setup(tr("Could not save the token in Keychain."))
        }
    }

    static func deleteToken(_ id: UUID) throws {
        let status = SecItemDelete(tokenQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReadError.setup(tr("Could not remove the token from Keychain."))
        }
    }

    private static func tokenQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func nonInteractiveKeychainContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var expanded: String { (self as NSString).expandingTildeInPath }
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
