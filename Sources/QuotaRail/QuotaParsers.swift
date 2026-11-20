import Foundation
import CoreFoundation

typealias JSON = [String: Any]

enum QuotaParsers {
    static func codex(_ result: JSON) throws -> Reading {
        let fallback = result["rateLimits"] as? JSON
        var buckets = (result["rateLimitsByLimitId"] as? [String: JSON]) ?? [:]
        if let fallback {
            let key = fallback["limitId"] as? String ?? "codex"
            if buckets[key] == nil { buckets[key] = fallback }
        }
        let keys = buckets.keys.sorted { left, right in
            if left == "codex" { return right != "codex" }
            if right == "codex" { return false }
            return left < right
        }
        let quotas = keys.flatMap { key -> [Quota] in
            guard let bucket = buckets[key] else { return [] }
            let qualifier = key == "codex" ? "" : (bucket["limitName"] as? String ?? key) + " · "
            var values = ["primary", "secondary"].compactMap { windowKey -> Quota? in
                guard let window = bucket[windowKey] as? JSON else { return nil }
                let label = duration(number(window["windowDurationMins"])) ??
                    (windowKey == "primary" ? tr("Primary limit") : tr("Secondary limit"))
                return Quota(id: key + "-" + windowKey, title: qualifier + label,
                             remaining: number(window["usedPercent"]).map { 100 - $0 },
                             reset: epoch(window["resetsAt"]))
            }
            if let spend = bucket["individualLimit"] as? JSON,
               let quota = Quota(id: key + "-spend", title: qualifier + tr("Individual budget"),
                                 remaining: number(spend["remainingPercent"]), reset: epoch(spend["resetsAt"])) {
                values.append(quota)
            }
            return values
        }
        return try reading(quotas)
    }

    static func claude(_ data: Data) throws -> Reading {
        let root = try object(data)
        let windows = root["rate_limits"] as? [String: JSON] ?? [:]
        let quotas = [("five_hour", tr("5 hours")), ("seven_day", tr("7 days")), ("spend_limit", tr("Budget"))].compactMap { key, label -> Quota? in
            guard let item = windows[key] else { return nil }
            return Quota(id: key, title: label,
                         remaining: number(item["used_percentage"]).map { 100 - $0 },
                         reset: epoch(item["resets_at"]))
        }
        return try reading(quotas)
    }

    static func claudeCLI(_ data: Data) throws -> Reading {
        let events = data.split(separator: 10).compactMap { try? object(Data($0)) }
        guard let result = events.last(where: { $0["type"] as? String == "result" }),
              result["is_error"] as? Bool == false,
              number(result["num_turns"]) == 0, number(result["total_cost_usd"]) == 0 else {
            throw ReadError.unavailable(tr("Claude CLI did not return a /usage report."))
        }
        let report = events.compactMap { $0["usage_report"] as? JSON }.last
        let windows = (report?["rate_limits"] as? JSON)?["limits"] as? [JSON] ?? []
        let quotas = windows.enumerated().compactMap { index, item -> Quota? in
            let kind = item["kind"] as? String
            let scope = item["scope"] as? JSON
            let name = (scope?["model"] as? JSON)?["display_name"] as? String
                ?? (scope?["surface"] as? JSON)?["display_name"] as? String
            let isSession = kind == "session" || item["group"] as? String == "session"
            let label: String
            if let name {
                label = (isSession ? tr("5 hr") : tr("7 days")) + " · " + name
            } else if isSession {
                label = tr("5 hours")
            } else {
                label = kind == "weekly_all" ? tr("7 days") : (kind ?? tr("Claude limit"))
            }
            let id: String
            if name == nil && isSession { id = "five_hour" }
            else if kind == "weekly_all" { id = "seven_day" }
            else if !isSession && name?.localizedCaseInsensitiveContains("Fable") == true { id = "fable-weekly" }
            else { id = String(index) }
            return Quota(id: id, title: label, remaining: number(item["percent"]).map { 100 - $0 },
                         reset: isoDate(item["resets_at"]) ?? epoch(item["resets_at"]))
        }
        return try reading(quotas)
    }

    static func cursor(_ data: Data) throws -> Reading {
        let root = try object(data)
        let reset = isoDate(root["billingCycleEnd"])
        let plan = (root["individualUsage"] as? JSON)?["plan"] as? JSON ?? [:]
        guard root["isUnlimited"] as? Bool != true, plan["enabled"] as? Bool != false else {
            throw ReadError.noQuota
        }
        let total = number(plan["totalPercentUsed"]).map { 100 - $0 }
            ?? percentRemaining(limit: plan["limit"], remaining: plan["remaining"], used: plan["used"])
        return try reading([
            Quota(id: "total", title: tr("Plan limit"), remaining: total, reset: reset),
            Quota(id: "auto", title: tr("Cursor models"), remaining: number(plan["autoPercentUsed"]).map { 100 - $0 }, reset: reset),
            Quota(id: "api", title: tr("External models"), remaining: number(plan["apiPercentUsed"]).map { 100 - $0 }, reset: reset)
        ].compactMap { $0 })
    }

    static func copilot(_ data: Data) throws -> Reading {
        let root = try object(data)
        let reset = isoDate(root["quota_reset_date_utc"]) ?? isoDate(root["quota_reset_date"])
        let snapshots = root["quota_snapshots"] as? [String: JSON] ??
            (root["quota_snapshots"] as? [JSON] ?? []).reduce(into: [String: JSON]()) { result, item in
                if let key = item["quota_id"] as? String { result[key] = item }
            }
        let quotas = [("premium_interactions", "Premium"), ("premium_requests", "Premium"),
                      ("chat", tr("Chat")), ("completions", tr("Completions"))].compactMap { key, label -> Quota? in
            if key == "premium_requests" && snapshots["premium_interactions"] != nil { return nil }
            guard let item = snapshots[key], item["unlimited"] as? Bool != true,
                  item["has_quota"] as? Bool != false else { return nil }
            let value = number(item["percent_remaining"])
                ?? percentRemaining(limit: item["entitlement"], remaining: item["remaining"], used: item["credits_used"])
            let creditBased = (item["token_based_billing"] ?? root["token_based_billing"]) as? Bool == true
            return Quota(id: key, title: creditBased && label == "Premium" ? tr("AI credits") : label,
                         remaining: value, reset: reset)
        }
        return try reading(quotas)
    }

    static func copilotCLI(_ result: JSON) throws -> Reading {
        let snapshots = result["quotaSnapshots"] as? [String: JSON] ?? [:]
        let quotas = [("premium_interactions", "Premium"), ("premium_requests", "Premium"),
                      ("chat", tr("Chat")), ("completions", tr("Completions"))].compactMap { key, label -> Quota? in
            guard let item = snapshots[key], item["isUnlimitedEntitlement"] as? Bool != true,
                  number(item["entitlementRequests"]).map({ $0 > 0 }) ?? true else { return nil }
            let remaining = number(item["remainingPercentage"]) ??
                percentRemaining(limit: item["entitlementRequests"], remaining: nil, used: item["usedRequests"])
            let title = item["tokenBasedBilling"] as? Bool == true && label == "Premium" ? tr("AI credits") : label
            // Copilot CLI can populate resetDate with the current snapshot timestamp.
            let reset = isoDate(item["resetDate"]).flatMap { $0 > Date().addingTimeInterval(120) ? $0 : nil }
            return Quota(id: key, title: title, remaining: remaining, reset: reset)
        }
        return try reading(quotas)
    }

    static func antigravity(_ data: Data) throws -> Reading {
        let root = try object(data)
        guard (root["status"] as? String)?.uppercased() == "SUCCESS",
              let command = root["command"] as? JSON,
              command["name"] as? String == "usage" else {
            throw ReadError.setup(tr("Sign in to the agy profile and check that /usage works."))
        }
        let groups = (command["data"] as? JSON)?["groups"] as? [JSON] ?? []
        let quotas = groups.flatMap { group -> [Quota] in
            let name = group["name"] as? String ?? tr("Models")
            return (group["buckets"] as? [JSON] ?? []).compactMap { item in
                guard let id = item["id"] as? String, item["enabled"] as? Bool != false,
                      let fraction = number(item["remaining_fraction"]), (0...1).contains(fraction) else { return nil }
                let window = item["window"] as? String ?? ""
                let label = switch window {
                case "weekly": tr("7 days")
                case "5h", "five_hour", "five-hour", "session": tr("5 hours")
                default: item["name"] as? String ?? tr("Limit")
                }
                return Quota(id: id, title: name + " · " + label,
                             remaining: fraction * 100, reset: isoDate(item["reset_time"]))
            }
        }
        return try reading(quotas)
    }

    static func object(_ data: Data) throws -> JSON {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? JSON else { throw ReadError.noQuota }
        return value
    }

    static func reading(_ quotas: [Quota], now: Date = Date()) throws -> Reading {
        var seen: Set<String> = []
        let unique = quotas.filter { seen.insert($0.id).inserted }
        let result = Reading(quotas: unique, observed: now)
        guard !result.active(at: now).isEmpty else { throw ReadError.noQuota }
        return result
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
            return n.doubleValue
        }
        if let text = value as? String, let n = Double(text), n.isFinite { return n }
        return nil
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withFullDate]
        return format.date(from: value)
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
    }

    private static func percentRemaining(limit: Any?, remaining: Any?, used: Any?) -> Double? {
        guard let limit = number(limit), limit > 0 else { return nil }
        if let left = number(remaining) { return left / limit * 100 }
        return number(used).map { (limit - $0) / limit * 100 }
    }

    private static func duration(_ minutes: Double?) -> String? {
        guard let minutes, minutes > 0, minutes < 1_000_000 else { return nil }
        if minutes.truncatingRemainder(dividingBy: 1_440) == 0 {
            let days = Int64(minutes / 1_440)
            return days == 1 ? tr("1 day") : tr("%lld days", days)
        }
        if minutes.truncatingRemainder(dividingBy: 60) == 0 {
            let hours = Int64(minutes / 60)
            return hours == 1 ? tr("1 hour") : tr("%lld hr", hours)
        }
        return tr("%lld min", Int64(minutes))
    }
}
