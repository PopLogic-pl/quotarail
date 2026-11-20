import Foundation

@main
struct QuotaRailTests {
    @MainActor
    static func main() async throws {
        let tests = Self()
        try tests.testCodexParsesRemainingAndDistinctModelWindows()
        try tests.testClaudeDoesNotInventWindowAndRejectsExpiredData()
        try tests.testClaudeUsageReportIsZeroTurnAndKeepsWeeklyWindows()
        try tests.testCopilotSupportsBothResponseShapes()
        try tests.testCopilotCLIReportsFiniteEntitlement()
        try tests.testMenuBarOrderingAndQuotaPairs()
        try tests.testCursorUsesPercentWithoutScalingTwice()
        try tests.testAntigravityUsesFractionAndIgnoresDisabledBuckets()
        try tests.testMultipleAccountsHaveIndependentSources()
        try await tests.testCodexHandshake()
        try tests.testRemovedProviderDoesNotDiscardSupportedAccounts()
        try await tests.testStartsEmptyAndKeepsUserAccounts()
        tests.testLocalization()
        print("13 smoke checks passed (\(appLocale.identifier)).")
    }

    func testCodexParsesRemainingAndDistinctModelWindows() throws {
        let result = try QuotaParsers.object(Data(#"""
        {
          "rateLimits": {"limitId":"codex","primary":{"usedPercent":14,"windowDurationMins":300}},
          "rateLimitsByLimitId": {
            "codex":{"primary":{"usedPercent":14,"windowDurationMins":300},
              "secondary":{"usedPercent":100,"windowDurationMins":10080}},
            "spark":{"limitName":"Spark","primary":{"usedPercent":0,"windowDurationMins":300}}
          }
        }
        """#.utf8))
        let reading = try QuotaParsers.codex(result)
        XCTAssertEqual(reading.quotas.map(\.value), ["86%", "0%", "100%"])
        XCTAssertEqual(reading.quotas.map(\.title), [tr("%lld hr", Int64(5)), tr("%lld days", Int64(7)), "Spark · " + tr("%lld hr", Int64(5))])
    }

    func testCodexHandshake() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let binary = temp.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        set -eu
        [ "$1" = "app-server" ]
        [ -d "$CODEX_HOME" ]
        IFS= read -r init
        case "$init" in *'"initialize"'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r ready
        case "$ready" in *'"initialized"'*) ;; *) exit 1 ;; esac
        IFS= read -r usage
        case "$usage" in *'account\/rateLimits\/read'*|*'account/rateLimits/read'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"method":"account/updated","params":{}}' \
          '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300}}}}'
        """#
        try Data((script + "\n").utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let reading = try await CLI.codex(profile: temp.path, executable: binary)
        XCTAssertEqual(reading.quotas.map(\.value), ["88%"])
    }

    func testClaudeDoesNotInventWindowAndRejectsExpiredData() throws {
        let data = Data(#"""
        {"rate_limits":{"five_hour":{"used_percentage":23.5},
                        "seven_day":{"used_percentage":10,"resets_at":1}}}
        """#.utf8)
        let reading = try QuotaParsers.claude(data)
        XCTAssertEqual(reading.active(at: Date()).map(\.remaining), [76.5])
        XCTAssertThrowsError(try QuotaParsers.claude(Data(#"{"rate_limits":{}}"#.utf8)))
    }

    func testClaudeUsageReportIsZeroTurnAndKeepsWeeklyWindows() throws {
        let events = #"""
        {"type":"assistant","usage_report":{"rate_limits":{"limits":[
          {"kind":"weekly_all","percent":1,"resets_at":"2095-11-27T02:00:00Z"},
          {"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":100}
        ]}}}
        """#.replacingOccurrences(of: "\n", with: "") + "\n"
        let finish = #"{"type":"result","is_error":false,"num_turns":0,"total_cost_usd":0}"#
        let reading = try QuotaParsers.claudeCLI(Data((events + finish).utf8))
        XCTAssertEqual(reading.quotas.map(\.title), [tr("7 days"), tr("7 days") + " · Fable"])
        XCTAssertEqual(reading.quotas.map(\.id), ["seven_day", "fable-weekly"])
        XCTAssertEqual(reading.quotas.map(\.value), ["99%", "0%"])
        XCTAssertThrowsError(try QuotaParsers.claudeCLI(Data((events + finish.replacingOccurrences(of: "num_turns\":0",
                                                                                                     with: "num_turns\":1")).utf8)))
    }

    func testCopilotSupportsBothResponseShapes() throws {
        let array = Data(#"{"quota_snapshots":[{"quota_id":"premium_requests","entitlement":100,"remaining":0}]}"#.utf8)
        let entries = Data(#"{"quota_snapshots":{"premium_interactions":{"percent_remaining":0.25},"chat":{"unlimited":true}}}"#.utf8)
        try XCTAssertEqual(try QuotaParsers.copilot(array).quotas.map(\.value), ["0%"])
        try XCTAssertEqual(try QuotaParsers.copilot(entries).quotas.map(\.value), ["<1%"])
    }

    func testCopilotCLIReportsFiniteEntitlement() throws {
        let data = Data(#"""
        {"quotaSnapshots":{
          "chat":{"entitlementRequests":0,"remainingPercentage":100,"isUnlimitedEntitlement":true},
          "premium_interactions":{"entitlementRequests":1500,"remainingPercentage":93.5,"tokenBasedBilling":true,
            "resetDate":"2020-01-01T00:00:00Z"}
        }}
        """#.utf8)
        let reading = try QuotaParsers.copilotCLI(QuotaParsers.object(data))
        XCTAssertEqual(reading.quotas.map(\.value), ["94%"])
        XCTAssertEqual(reading.quotas.map(\.title), [tr("AI credits")])
        XCTAssertEqual(reading.quotas.first?.reset, nil)
    }

    func testMenuBarOrderingAndQuotaPairs() throws {
        let personal = Account(provider: .claude)
        var work = Account(provider: .claude, number: 2)
        work.path = "~/.claude-work"
        let codex = Account(provider: .codex)
        let cursor = Account(provider: .cursor)
        let antigravity = Account(provider: .antigravity)
        let copilot = Account(provider: .copilot)
        XCTAssertEqual(MenuBarReadout.ordered([copilot, work, codex, personal, antigravity, cursor]),
                       [personal, codex, cursor, antigravity, work, copilot])
        func quota(_ id: String, _ value: Double) -> Quota {
            Quota(id: id, title: id, remaining: value)!
        }
        XCTAssertEqual(MenuBarReadout.value(for: personal, quotas: [quota("fable-weekly", 80), quota("seven_day", 99)]),
                       "99/80%")
        XCTAssertEqual(MenuBarReadout.value(for: codex, quotas: [quota("codex-secondary", 18), quota("codex-primary", 63)]),
                       "63%")
        XCTAssertEqual(MenuBarReadout.value(for: cursor, quotas: [quota("total", 81), quota("api", 57), quota("auto", 0)]),
                       "0/57%")
        XCTAssertEqual(MenuBarReadout.value(for: antigravity, quotas: [quota("3p-5h", 1), quota("gemini-weekly", 88), quota("gemini-5h", 100)]),
                       "100/88%")
        XCTAssertEqual(MenuBarReadout.value(for: work, quotas: [quota("seven_day", 18), quota("five_hour", 72)]),
                       "72/18%")
        XCTAssertEqual(MenuBarReadout.value(for: work, quotas: [quota("seven_day", 18)]), "–/18%")
    }

    func testCursorUsesPercentWithoutScalingTwice() throws {
        let cursor = Data(#"{"individualUsage":{"plan":{"enabled":true,"totalPercentUsed":28}}}"#.utf8)
        try XCTAssertEqual(try QuotaParsers.cursor(cursor).quotas.map(\.remaining), [72])
        XCTAssertThrowsError(try QuotaParsers.cursor(Data(#"{"individualUsage":{"plan":{"totalPercentUsed":false}}}"#.utf8)))
    }

    func testAntigravityUsesFractionAndIgnoresDisabledBuckets() throws {
        let data = Data(#"""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini",
          "buckets":[{"id":"weekly","window":"weekly","remaining_fraction":0.54},
                     {"id":"session","enabled":false,"remaining_fraction":0}]}]}}}
        """#.utf8)
        try XCTAssertEqual(try QuotaParsers.antigravity(data).quotas.map(\.value), ["54%"])
    }

    @MainActor
    func testRemovedProviderDoesNotDiscardSupportedAccounts() throws {
        let suite = "pl.poplogic.quotarail.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var local = Account(provider: .claude)
        local.name = "Personal profile"
        let data = try JSONEncoder().encode(local)
        let old = #"{"provider":"gemini"}"#
        let saved = Data(("[\(String(decoding: data, as: UTF8.self)),\(old)]").utf8)
        defaults.set(saved, forKey: "trackedAccounts.v1")
        let store = Store(defaults: defaults)
        XCTAssertEqual(store.accounts, [local])
    }

    @MainActor
    func testMultipleAccountsHaveIndependentSources() throws {
        let suite = "pl.poplogic.quotarail.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        var personal = Account(provider: .codex)
        personal.name = "Personal"
        try store.save(personal, token: "", forgetToken: false)
        try store.save(Account(provider: .claude), token: "", forgetToken: false)
        var otherClaude = Account(provider: .claude, number: 2)
        otherClaude.path = "~/.claude-work"
        try store.save(otherClaude, token: "", forgetToken: false)
        var work = Account(provider: .codex, number: 2)
        work.path = "~/.codex"
        XCTAssertThrowsError(try store.save(work, token: "", forgetToken: false))
        work.path = "~/.codex-work"
        work.name = "Work"
        try store.save(work, token: "", forgetToken: false)
        XCTAssertEqual(store.pinned.filter { $0.provider == .codex }.map(\.name), ["Personal", "Work"])
        var third = Account(provider: .codex, number: 3)
        third.path = "~/.codex-work"
        XCTAssertThrowsError(try store.save(third, token: "", forgetToken: false))
        third.path = "~/.codex-third"
        try store.save(third, token: "", forgetToken: false)
        XCTAssertEqual(store.pinned.filter { $0.provider == .codex }.count, 3)
        var anotherClaude = store.draft(for: .claude)
        XCTAssertThrowsError(try store.save(anotherClaude, token: "", forgetToken: false))
        anotherClaude.path = "~/.claude-extra"
        try store.save(anotherClaude, token: "", forgetToken: false)
        XCTAssertEqual(store.pinned.filter { $0.provider == .claude }.count, 3)
    }

    @MainActor
    func testStartsEmptyAndKeepsUserAccounts() async throws {
        let suite = "pl.poplogic.quotarail.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(defaults: defaults)
        XCTAssertEqual(store.accounts, [])
        XCTAssertEqual(store.pinned, [])
        await store.refresh()
        XCTAssertEqual(store.lastRefresh, nil)

        var account = store.draft(for: .claude)
        account.name = "My account"
        try store.save(account, token: "", forgetToken: false)
        let relaunched = Store(defaults: defaults)
        XCTAssertEqual(relaunched.accounts, [account])
        try relaunched.remove(account)
        XCTAssertEqual(Store(defaults: defaults).accounts, [])
    }

    func testLocalization() {
        let language = CommandLine.arguments.last!
        XCTAssertEqual(appLocale.identifier, language)
        XCTAssertEqual(tr("Add account"), language == "pl" ? "Dodaj konto" : "Add account")
        XCTAssertEqual(tr("Account %lld", Int64(2)), language == "pl" ? "Konto 2" : "Account 2")
        XCTAssertEqual(tr("%@ remaining", "80%"), language == "pl" ? "80% pozostało" : "80% remaining")
    }
}

private func XCTAssertEqual<Value: Equatable>(_ lhs: @autoclosure () throws -> Value, _ rhs: Value,
                                             line: UInt = #line) rethrows {
    let value = try lhs()
    precondition(value == rhs, "Line \(line): expected \(rhs), got \(value)")
}

private func XCTAssertThrowsError(_ call: @autoclosure () throws -> Any, line: UInt = #line) {
    do { _ = try call() } catch { return }
    preconditionFailure("Line \(line): expected an error")
}
