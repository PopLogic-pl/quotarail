import Foundation

enum MenuBarReadout {
    enum Group: Int {
        case claudePersonal, codex, cursor, antigravity, claudeAdditional, copilot
    }

    static func group(of account: Account) -> Group {
        switch account.provider {
        case .codex: return .codex
        case .cursor: return .cursor
        case .antigravity: return .antigravity
        case .copilot: return .copilot
        case .claude:
            let profile = URL(fileURLWithPath: account.path.expanded).standardizedFileURL.path
            if account.path.isEmpty || profile == NSHomeDirectory() + "/.claude" { return .claudePersonal }
            return .claudeAdditional
        }
    }

    static func ordered(_ accounts: [Account]) -> [Account] {
        accounts.enumerated().sorted { lhs, rhs in
            let left = group(of: lhs.element)
            let right = group(of: rhs.element)
            return left == right ? lhs.offset < rhs.offset : left.rawValue < right.rawValue
        }.map(\.element)
    }

    static func value(for account: Account, quotas: [Quota]) -> String {
        func quota(_ id: String) -> Quota? { quotas.first { $0.id == id } }
        let weekly = quota("seven_day")
        let session = quota("five_hour")

        switch group(of: account) {
        case .claudePersonal:
            let main = weekly ?? session
            if let fable = quota("fable-weekly") { return pair(main, fable) }
            return main?.value ?? "–"
        case .claudeAdditional:
            return pair(session, weekly)
        case .codex:
            return (quota("codex-primary") ?? quota("codex-secondary") ?? quotas.first)?.value ?? "–"
        case .cursor:
            if quota("auto") != nil || quota("api") != nil { return pair(quota("auto"), quota("api")) }
            return quota("total")?.value ?? "–"
        case .antigravity:
            return pair(quota("gemini-5h"), quota("gemini-weekly"))
        case .copilot:
            return (quota("premium_interactions") ?? quota("premium_requests") ?? quotas.first)?.value ?? "–"
        }
    }

    private static func pair(_ first: Quota?, _ second: Quota?) -> String {
        guard first != nil || second != nil else { return "–" }
        let left = first.map { String($0.value.dropLast()) } ?? "–"
        let right = second.map { String($0.value.dropLast()) } ?? "–"
        return left + "/" + right + "%"
    }
}
