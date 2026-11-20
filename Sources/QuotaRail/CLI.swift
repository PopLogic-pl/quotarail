import Foundation
import Darwin

enum CLI {
    static let home = NSHomeDirectory()
    static let paths = [home + "/.local/bin", home + "/.npm-global/bin",
                        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func find(_ name: String) -> URL? {
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let candidates = (paths + inherited.filter { $0.hasPrefix("/") }).map { $0 + "/" + name }
        let bundled = name == "codex" ? ["/Applications/Codex.app/Contents/Resources/codex",
                                         "/Applications/ChatGPT.app/Contents/Resources/codex"] : []
        return (candidates + bundled).first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    static func environment(overrides: [String: String]) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        values["PATH"] = (paths + [values["PATH"] ?? ""]).joined(separator: ":")
        values.merge(overrides) { _, new in new }
        return values
    }

    static func codex(profile: String, executable: URL? = nil) async throws -> Reading {
        guard let binary = executable ?? find("codex") else {
            throw ReadError.setup(tr("Install Codex CLI and sign in to your account."))
        }
        return try await Task.detached(priority: .utility) {
            var env = environment(overrides: ["CODEX_HOME": profile])
            for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_THREAD_ID", "CODEX_ACCOUNT_ID"] {
                env.removeValue(forKey: key)
            }
            let process = try Child(executable: binary, arguments: ["app-server"],
                                    environment: env, timeout: 18)
            try process.send([
                "id": 1, "method": "initialize",
                "params": ["clientInfo": ["name": "quotarail", "title": "QuotaRail", "version": AppInfo.version]]
            ])
            _ = try process.response(to: 1)
            try process.send(["method": "initialized"])
            try process.send(["id": 2, "method": "account/rateLimits/read"])
            return try QuotaParsers.codex(process.response(to: 2))
        }.value
    }

    static func claude(profile: String?) async throws -> Reading {
        try await Task.detached(priority: .utility) {
            guard let binary = try claudeUsageBinary() else {
                throw ReadError.setup(tr("Update Claude Code to read limits from the CLI."))
            }
            var env = environment(overrides: [:])
            if let profile {
                env["CLAUDE_CONFIG_DIR"] = profile
                for key in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
                            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] {
                    env.removeValue(forKey: key)
                }
            } else {
                env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            }
            let auth = try Child(executable: binary, arguments: ["auth", "status", "--json"],
                                 environment: env, timeout: 6)
            let status = try? QuotaParsers.object(auth.allOutput())
            guard status?["loggedIn"] as? Bool == true else {
                let message = profile == nil
                    ? tr("Run claude auth login.")
                    : tr("Run claude auth login with CLAUDE_CONFIG_DIR set to this profile.")
                throw ReadError.setup(message)
            }
            let report = try Child(executable: binary,
                                   arguments: ["--print", "/usage", "--output-format", "stream-json", "--verbose",
                                               "--safe-mode", "--no-session-persistence", "--tools", "",
                                               "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#],
                                   environment: env, timeout: 22)
            return try QuotaParsers.claudeCLI(report.allOutput())
        }.value
    }

    private static func claudeUsageBinary() throws -> URL? {
        let root = URL(fileURLWithPath: home + "/Library/Application Support/Claude/claude-code", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let bundled = folders.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .map { $0.appendingPathComponent("claude.app/Contents/MacOS/claude") }
        let candidates = [find("claude")].compactMap { $0 } + bundled
        for binary in candidates where FileManager.default.isExecutableFile(atPath: binary.path) {
            let probe = try Child(executable: binary, arguments: ["--version"],
                                  environment: environment(overrides: [:]), timeout: 4)
            let output = String(decoding: try probe.allOutput(), as: UTF8.self)
            if let range = output.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression),
               String(output[range]).compare("2.1.316", options: .numeric) != .orderedAscending {
                return binary
            }
        }
        return nil
    }

    static func copilot() async throws -> Reading {
        return try await Task.detached(priority: .utility) {
            if let binary = find("copilot") {
                do {
                    let process = try Child(executable: binary, arguments: ["--headless", "--no-auto-update", "--stdio"],
                                            environment: environment(overrides: [:]), timeout: 12)
                    try process.send(["jsonrpc": "2.0", "id": 1, "method": "connect", "params": JSON()], framed: true)
                    _ = try process.copilotResponse(to: 1)
                    try process.send(["jsonrpc": "2.0", "id": 2, "method": "account.getQuota", "params": JSON()], framed: true)
                    return try QuotaParsers.copilotCLI(process.copilotResponse(to: 2))
                } catch {
                    guard let github = find("gh"), let fallback = try? githubCopilot(github) else { throw error }
                    return fallback
                }
            }
            guard let binary = find("gh") else {
                throw ReadError.setup(tr("Sign in to Copilot CLI or GitHub CLI."))
            }
            return try githubCopilot(binary)
        }.value
    }

    private static func githubCopilot(_ binary: URL) throws -> Reading {
        let process = try Child(executable: binary, arguments: ["api", "/copilot_internal/user", "--hostname", "github.com"],
                                environment: environment(overrides: ["GH_PROMPT_DISABLED": "1"]), timeout: 18)
        let data = try process.allOutput()
        guard !data.isEmpty else {
            throw ReadError.setup(tr("Check your gh sign-in and Copilot access."))
        }
        return try QuotaParsers.copilot(data)
    }

    static func antigravity(profile: String) async throws -> Reading {
        guard let binary = find("agy") else {
            throw ReadError.setup(tr("Install Antigravity CLI (agy) and sign in."))
        }
        return try await Task.detached(priority: .utility) {
            let files = FileManager.default
            let temp = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try files.createDirectory(at: temp, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: temp) }
            for launcher in ["open", "xdg-open"] {
                try files.createSymbolicLink(atPath: temp.appendingPathComponent(launcher).path,
                                             withDestinationPath: "/usr/bin/false")
            }
            var env = environment(overrides: ["HOME": profile, "BROWSER": "/usr/bin/false"])
            env["PATH"] = temp.path + ":" + (env["PATH"] ?? "")
            if URL(fileURLWithPath: profile).standardizedFileURL.path != home {
                env["SSH_TTY"] = "/dev/null"
                env["XDG_CONFIG_HOME"] = profile + "/.config"
            }
            let version = try Child(executable: binary, arguments: ["--version"],
                                    environment: env, directory: temp, timeout: 4)
            let output = String(decoding: try version.allOutput(), as: UTF8.self)
            guard let range = output.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression),
                  String(output[range]).compare("1.1.11", options: .numeric) != .orderedAscending else {
                throw ReadError.setup(tr("Update agy to version 1.1.11 or later."))
            }
            let report = try Child(executable: binary, arguments: ["-p", "/usage", "--output-format", "json"],
                                   environment: env, directory: temp, timeout: 35)
            return try QuotaParsers.antigravity(report.allOutput())
        }.value
    }
}

private final class Child {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let deadline: TimeInterval
    private var buffer = Data()
    private var bytesRead = 0

    init(executable: URL, arguments: [String], environment: [String: String],
         directory: URL = FileManager.default.temporaryDirectory, timeout: TimeInterval) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ReadError.unavailable(tr("Could not start the command-line tool."))
        }
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    func send(_ request: JSON, framed: Bool = false) throws {
        var data = try JSONSerialization.data(withJSONObject: request)
        if framed {
            data = Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data
        } else {
            data.append(10)
        }
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch {
            throw ReadError.unavailable(tr("The command-line tool exited before reporting limits."))
        }
    }

    func copilotResponse(to id: Int) throws -> JSON {
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let end = buffer.range(of: separator) {
                let headers = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let contentLength = headers.first { $0.lowercased().hasPrefix("content-length:") }
                guard let contentLength,
                      let size = Int(String(contentLength.dropFirst("content-length:".count)).trimmed),
                      (1...1_048_576).contains(size) else {
                    throw ReadError.unavailable(tr("QuotaRail did not recognize the Copilot CLI response."))
                }
                if let stop = buffer.index(end.upperBound, offsetBy: size, limitedBy: buffer.endIndex) {
                    let message = try QuotaParsers.object(Data(buffer[end.upperBound..<stop]))
                    buffer.removeSubrange(..<stop)
                    guard message["id"] as? Int == id else { continue }
                    if let result = message["result"] as? JSON { return result }
                    let error = (message["error"] as? JSON)?["message"] as? String ?? ""
                    if error.localizedCaseInsensitiveContains("auth") {
                        throw ReadError.setup(tr("Check the account signed in to Copilot CLI."))
                    }
                    throw ReadError.unavailable(tr("Copilot CLI did not return a quota for this account."))
                }
            }
            guard let chunk = try readChunk() else {
                throw ReadError.unavailable(tr("Copilot CLI exited without reporting limits."))
            }
            buffer.append(chunk)
        }
    }

    func response(to id: Int) throws -> JSON {
        while let line = try nextLine() {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? JSON,
                  message["id"] as? Int == id else { continue }
            if let result = message["result"] as? JSON { return result }
            let error = (message["error"] as? JSON)?["message"] as? String ?? ""
            let lower = error.lowercased()
            if lower.contains("auth") || lower.contains("401") || lower.contains("403") {
                throw ReadError.setup(tr("Sign in to ChatGPT in this Codex CLI profile."))
            }
            throw ReadError.unavailable(tr("Codex CLI could not read limits. Check your connection and sign-in."))
        }
        throw ReadError.unavailable(tr("Codex CLI exited without responding."))
    }

    func allOutput() throws -> Data {
        try input.fileHandleForWriting.close()
        var data = Data()
        while let chunk = try readChunk() { data.append(chunk) }
        return data
    }

    private func nextLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard let chunk = try readChunk() else {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(chunk)
        }
    }

    private func readChunk() throws -> Data? {
        let descriptor = output.fileHandleForReading.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let timeLeft = deadline - ProcessInfo.processInfo.systemUptime
            guard timeLeft > 0 else {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                throw ReadError.timeout
            }
            var wait = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&wait, 1, Int32((timeLeft * 1_000).rounded(.up)))
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw ReadError.noQuota }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ReadError.noQuota }
            if count == 0 { return nil }
            bytesRead += count
            guard bytesRead <= 1_048_576 else { throw ReadError.noQuota }
            return Data(bytes.prefix(count))
        }
    }
}
