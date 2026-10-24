import Foundation

enum UsageFetcherError: LocalizedError {
    case unauthorized
    case httpStatus(Int, String)
    case badPayload
    case transport(String)
    case timedOut
    /// HTTP 429. Seconds from `Retry-After`, when the server sent one.
    case rateLimited(TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Grok session expired."
        case .httpStatus(let code, _):
            return "Grok billing returned an error (\(code))."
        case .badPayload:
            return "Unexpected billing response from Grok."
        case .transport:
            return "Network error while fetching usage."
        case .timedOut:
            return "Timed out fetching usage."
        case .rateLimited:
            return "Grok usage is rate-limited. Retrying shortly."
        }
    }

    var retryAfter: TimeInterval? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }

    var isAuthIssue: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var isTransient: Bool {
        switch self {
        case .timedOut, .transport, .rateLimited:
            return true
        case .unauthorized, .httpStatus, .badPayload:
            return false
        }
    }
}

/// Fetches billing / quota metadata only (not chat/completions).
enum UsageFetcher {
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let monthlyURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private static let userURL = URL(string: "https://cli-chat-proxy.grok.com/v1/user")!
    private static let clientVersion = "0.2.118"

    private static let overallTimeout: TimeInterval = 12

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func fetch(token: String, subscriptionTier: Int?) async throws -> UsageSnapshot {
        async let creditsData = getJSON(url: creditsURL, token: token)
        async let monthlyData = optionalGetJSON(url: monthlyURL, token: token)
        async let settingsData = optionalGetJSON(url: settingsURL, token: token)
        async let userData = optionalGetJSON(url: userURL, token: token)

        let credits = try await creditsData
        let monthly = await monthlyData
        let settings = await settingsData
        let user = await userData

        return try parse(
            creditsRoot: credits,
            monthlyRoot: monthly,
            settingsRoot: settings,
            userRoot: user,
            subscriptionTier: subscriptionTier
        )
    }

    // MARK: - HTTP

    private static func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-cli/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("grokbar", forHTTPHeaderField: "x-grok-client-identifier")
        return request
    }

    private static func getJSON(url: URL, token: String) async throws -> [String: Any] {
        let request = authorizedRequest(url: url, token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTimeout(seconds: overallTimeout) {
                try await session.data(for: request)
            }
        } catch is TimeoutError {
            throw UsageFetcherError.timedOut
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw UsageFetcherError.timedOut
        } catch {
            throw UsageFetcherError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageFetcherError.transport("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageFetcherError.unauthorized
        }
        if http.statusCode == 429 {
            throw UsageFetcherError.rateLimited(retryAfter(http))
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageFetcherError.httpStatus(http.statusCode, String(body.prefix(180)))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetcherError.badPayload
        }
        return root
    }

    /// `Retry-After` as delta-seconds or an HTTP date.
    private static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func optionalGetJSON(url: URL, token: String) async -> [String: Any]? {
        try? await getJSON(url: url, token: token)
    }

    // MARK: - Parse

    private static func parse(
        creditsRoot: [String: Any],
        monthlyRoot: [String: Any]?,
        settingsRoot: [String: Any]?,
        userRoot: [String: Any]?,
        subscriptionTier: Int?
    ) throws -> UsageSnapshot {
        guard let config = creditsRoot["config"] as? [String: Any] else {
            throw UsageFetcherError.badPayload
        }

        var periodType: String?
        var periodStart: Date?
        var periodEnd: Date?

        if let current = config["currentPeriod"] as? [String: Any] {
            periodType = current["type"] as? String
            periodStart = parseDate(current["start"])
            periodEnd = parseDate(current["end"])
        }
        if periodStart == nil {
            periodStart = parseDate(config["billingPeriodStart"])
        }
        if periodEnd == nil {
            periodEnd = parseDate(config["billingPeriodEnd"])
        }

        let usedPercent: Double
        if let percent = doubleValue(config["creditUsagePercent"]) {
            usedPercent = percent
        } else if periodStart != nil || periodEnd != nil || config["currentPeriod"] != nil {
            usedPercent = 0
        } else if
            let monthly = moneyCents(config["monthlyLimit"]),
            let used = moneyCents(config["used"] ?? (config["usage"] as? [String: Any])?["totalUsed"]),
            monthly > 0
        {
            usedPercent = min(100, Double(used) / Double(monthly) * 100)
        } else {
            throw UsageFetcherError.badPayload
        }

        var products: [ProductUsage] = []
        if let rawProducts = config["productUsage"] as? [[String: Any]] {
            products = rawProducts.compactMap { item in
                guard let product = item["product"] as? String else { return nil }
                let percent = doubleValue(item["usagePercent"]) ?? 0
                return ProductUsage(product: product, usagePercent: percent)
            }
            .sorted { $0.usagePercent > $1.usagePercent }
        }

        let prepaid = moneyCents(config["prepaidBalance"])
        let unified = (config["isUnifiedBillingUser"] as? Bool) ?? false

        var monthlyLimit: Int?
        var monthlyUsed: Int?
        if let monthlyConfig = monthlyRoot?["config"] as? [String: Any] {
            monthlyLimit = moneyCents(monthlyConfig["monthlyLimit"])
            monthlyUsed = moneyCents(monthlyConfig["used"])
        }

        var planDisplay: String?
        if let settingsRoot {
            let label = (settingsRoot["subscription_tier_display"] as? String)
                ?? (settingsRoot["subscription_tier"] as? String)
            if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                planDisplay = label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var accountName: String?
        var accountEmail: String?
        if let userRoot {
            accountEmail = userRoot["email"] as? String
            if let name = userRoot["name"] as? String, !name.isEmpty {
                accountName = name
            } else {
                let first = (userRoot["firstName"] as? String) ?? (userRoot["given_name"] as? String) ?? ""
                let last = (userRoot["lastName"] as? String) ?? (userRoot["family_name"] as? String) ?? ""
                let combined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                if !combined.isEmpty { accountName = combined }
            }
        }

        return UsageSnapshot(
            usedPercent: usedPercent,
            periodType: periodType,
            periodStart: periodStart,
            periodEnd: periodEnd,
            productUsage: products,
            prepaidBalanceCents: prepaid,
            isUnifiedBilling: unified,
            monthlyLimitCents: monthlyLimit,
            monthlyUsedCents: monthlyUsed,
            subscriptionTier: subscriptionTier,
            planDisplayName: planDisplay,
            accountName: accountName,
            accountEmail: accountEmail,
            fetchedAt: Date(),
            source: "cli-chat-proxy"
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let n = Double(s) { return n }
        return nil
    }

    private static func moneyCents(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let obj = value as? [String: Any] {
            if let n = obj["val"] as? Int { return n }
            if let n = obj["val"] as? Double { return Int(n) }
            if let n = obj["val"] as? NSNumber { return n.intValue }
        }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Timeout

private struct TimeoutError: Error {}

private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let ns = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
