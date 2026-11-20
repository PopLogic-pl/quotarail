import Foundation
import Security
import SQLite3

enum Usage {
    static func fetch(_ account: Account) async throws -> Reading {
        switch account.provider {
        case .codex:
            return try await CLI.codex(profile: try folder(account.path))
        case .claude:
            let profile = account.path.isEmpty || account.path.expanded == CLI.home + "/.claude"
                ? nil : try folder(account.path)
            do {
                return try await CLI.claude(profile: profile)
            } catch {
                if let reading = statusline(account) { return reading }
                throw error
            }
        case .antigravity:
            return try await CLI.antigravity(profile: try folder(account.path))
        case .cursor:
            let cookie = try await Task.detached(priority: .utility) {
                try cursorCookie(account)
            }.value
            let data = try await get("https://cursor.com/api/usage-summary",
                                     headers: ["Cookie": "WorkosCursorSessionToken=" + cookie])
            return try QuotaParsers.cursor(data)
        case .copilot:
            guard let token = try Storage.token(account.id), !token.isEmpty else {
                return try await CLI.copilot()
            }
            let data = try await get("https://api.github.com/copilot_internal/user",
                                     headers: ["Authorization": "Bearer " + token,
                                               "X-GitHub-Api-Version": "2025-05-01"])
            return try QuotaParsers.copilot(data)
        }
    }

    private static func statusline(_ account: Account) -> Reading? {
        guard let data = try? Data(contentsOf: Storage.claudeFile(account.id)),
              let reading = try? JSONDecoder().decode(Reading.self, from: data),
              Date().timeIntervalSince(reading.observed) <= 15 * 60,
              !reading.active(at: Date()).isEmpty else { return nil }
        return reading
    }

    private static func folder(_ path: String) throws -> String {
        let path = path.expanded
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ReadError.setup(tr("Choose an existing profile folder.")) }
        return path
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private static func get(_ url: String, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaRail/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ReadError.noQuota }
        guard status == 200 else { throw ReadError.http(status) }
        return data
    }

    private static func cursorCookie(_ account: Account) throws -> String {
        if let token = try Storage.token(account.id), !token.isEmpty {
            return try cookie(from: token)
        }
        let files = FileManager.default
        if !account.path.isEmpty {
            let path = account.path.expanded
            if let token = readCursorToken(at: path) { return try cookie(from: token) }
            throw ReadError.setup(tr("The file does not contain a Cursor session."))
        }
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let sources = [(xdg ?? CLI.home + "/.config") + "/cursor/auth.json", CLI.home + "/.cursor/auth.json",
                       CLI.home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"]
        for path in sources where files.isReadableFile(atPath: path) {
            if let token = readCursorToken(at: path), let value = try? cookie(from: token) { return value }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cursor-access-token",
            kSecAttrAccount as String: "cursor-user",
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: Storage.nonInteractiveKeychainContext()
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let token = String(data: data, encoding: .utf8) {
            return try cookie(from: token)
        }
        throw ReadError.setup(tr("Sign in to Cursor, choose a profile file, or enter a session token."))
    }

    private static func readCursorToken(at path: String) -> String? {
        if path.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return (try? QuotaParsers.object(data))?["accessToken"] as? String
        }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard result == SQLITE_OK else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }

    private static func cookie(from token: String) throws -> String {
        let cleaned = token.trimmed
        let prefix = "WorkosCursorSessionToken="
        let raw = cleaned.hasPrefix(prefix) ? String(cleaned.dropFirst(prefix.count)) : cleaned
        let value = raw.removingPercentEncoding ?? raw
        let pieces = value.components(separatedBy: "::")
        if pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty {
            return try encodeCookie(pieces[0], token: pieces[1])
        }
        let jwt = value.split(separator: ".")
        if jwt.count == 3 {
            let payload = String(jwt[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: padded),
               let subject = (try? QuotaParsers.object(data))?["sub"] as? String {
                return try encodeCookie(subject, token: value)
            }
        }
        throw ReadError.setup(tr("QuotaRail does not recognize this Cursor session token format."))
    }

    private static func encodeCookie(_ user: String, token: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let user = user.addingPercentEncoding(withAllowedCharacters: allowed),
              let token = token.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ReadError.noQuota }
        return user + "%3A%3A" + token
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
