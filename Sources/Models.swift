import Foundation

// MARK: - Auth

struct AuthIdentity: Equatable, Sendable {
    var email: String?
    var teamID: String?
    var principalType: String?
    var authMode: String?
    var accessToken: String
    var expiresAt: Date?
    /// OIDC access-token claim used as a coarse plan signal when available.
    var tier: Int?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

// MARK: - Usage

struct ProductUsage: Identifiable, Equatable, Sendable {
    var id: String { product }
    var product: String
    var usagePercent: Double

    var displayName: String {
        switch product {
        case "GrokBuild": return "Build"
        case "GrokChat": return "Chat"
        case "GrokImagine": return "Imagine"
        case "GrokVoice": return "Voice"
        case "GrokAPI", "API", "Api": return "API"
        default:
            return product.replacingOccurrences(of: "Grok", with: "")
        }
    }
}

struct UsageSnapshot: Equatable, Sendable {
    /// Weekly (or current) pool usage 0…100.
    var usedPercent: Double
    var periodType: String?
    var periodStart: Date?
    var periodEnd: Date?
    var productUsage: [ProductUsage]
    /// Extra usage credits balance in USD cents.
    var prepaidBalanceCents: Int?
    var isUnifiedBilling: Bool
    /// Included allowance for the calendar billing month (cents), when known.
    var monthlyLimitCents: Int?
    /// Included allowance already consumed this calendar month (cents).
    var monthlyUsedCents: Int?
    /// Coarse plan signal from OIDC `tier` claim.
    var subscriptionTier: Int?
    /// Display name from the Grok settings API when available.
    var planDisplayName: String? = nil
    var accountName: String? = nil
    var accountEmail: String? = nil
    var subscriptionPeriodEnd: Date? = nil
    var subscriptionCancelsAtEnd: Bool = false
    var fetchedAt: Date
    var source: String

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var resetsIn: TimeInterval? {
        guard let periodEnd else { return nil }
        return periodEnd.timeIntervalSinceNow
    }

    var cycleLabel: String {
        switch periodType {
        case "USAGE_PERIOD_TYPE_WEEKLY":
            return "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY":
            return "Monthly"
        default:
            if let start = periodStart, let end = periodEnd {
                let days = end.timeIntervalSince(start) / 86_400
                if days >= 6 && days <= 8 { return "Weekly" }
                if days >= 27 && days <= 32 { return "Monthly" }
            }
            return "Usage"
        }
    }

    /// Best-effort human plan name for the detail menu.
    var subscriptionLabel: String {
        if let planDisplayName, !planDisplayName.isEmpty {
            return planDisplayName
        }
        if let name = SubscriptionCatalog.name(forTier: subscriptionTier, monthlyLimitCents: monthlyLimitCents) {
            return name
        }
        if isUnifiedBilling {
            return "SuperGrok (unified)"
        }
        return "Grok"
    }
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded(UsageSnapshot)
    /// Recoverable problem: not signed in, Grok missing, session expired, etc.
    case unavailable(title: String, hint: String)
    /// Transient failure with no cached snapshot to show.
    case failed(String)
}

// MARK: - Subscription naming

/// Heuristic mapping from known signals to plan names.
/// xAI does not currently return a stable plan string on the billing endpoint.
enum SubscriptionCatalog {
    static func name(forTier tier: Int?, monthlyLimitCents: Int?) -> String? {
        if let monthlyLimitCents {
            // Observed included-credit pools (USD cents). Values can change; treat as hints.
            switch monthlyLimitCents {
            case 0:
                return "Free"
            case 1...25_000:
                return "SuperGrok Lite"
            case 25_001...100_000:
                return "SuperGrok"
            case 100_001...:
                return "SuperGrok Heavy"
            default:
                break
            }
        }

        if let tier {
            switch tier {
            case 0, 1: return "Free"
            case 2: return "SuperGrok Lite"
            case 3, 4: return "SuperGrok"
            case 5...: return "SuperGrok Heavy"
            default: break
            }
        }

        return nil
    }
}

// MARK: - Formatting

enum Formatters {
    /// Reset date + time without year, e.g. "Aug 13, 3:46 PM".
    static var resetDateTime: DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMd jm")
        return f
    }

    static var currency: NumberFormatter {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }
}

func expectedPace(start: Date?, end: Date?, fallbackDays: Double) -> Double? {
    guard let end else { return nil }
    let start = start ?? end.addingTimeInterval(-fallbackDays * 86_400)
    let span = end.timeIntervalSince(start)
    guard span > 0 else { return nil }
    let frac = Date().timeIntervalSince(start) / span
    guard frac.isFinite else { return nil }
    return min(1, max(0, frac))
}

/// Countdown formatting.
/// - compact (menu bar): days when ≥ 1 day, otherwise hours (matches Grokbar on Omarchy).
/// - full (detail panel): days and hours when ≥ 1 day; otherwise hours (and minutes under 1h).
/// Menu bar "days left" suffix. Whole days remaining, rounded down ("3d" for 3 days 20 h);
/// under one day shows "<1d". Returns nil when the reset date is missing or already past,
/// so the bar falls back to the percentage alone.
func daysLeftLabel(_ interval: TimeInterval?) -> String? {
    guard let interval, interval.isFinite, interval > 0 else { return nil }
    if interval < 86_400 { return "<1d" }
    return "\(Int(interval / 86_400))d"
}

func formatCountdown(_ interval: TimeInterval?, compact: Bool = false) -> String? {
    guard let interval else { return nil }
    if interval <= 0 {
        return compact ? "now" : "Resets soon"
    }

    let total = Int(interval.rounded())
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60

    if compact {
        if days >= 1 {
            return "\(days)d"
        }
        return "\(max(hours, 1))h"
    }

    // Detail panel: always include days and hours when a full day or more remains.
    if days >= 1 {
        let dayPart = "\(days) day\(days == 1 ? "" : "s")"
        let hourPart = "\(hours) hour\(hours == 1 ? "" : "s")"
        return "\(dayPart), \(hourPart)"
    }
    if hours >= 1 {
        if minutes > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s"), \(minutes) min"
        }
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }
    return "\(max(minutes, 1)) min"
}

func formatUSD(cents: Int) -> String {
    let dollars = Double(cents) / 100.0
    return Formatters.currency.string(from: NSNumber(value: dollars))
        ?? String(format: "$%.2f", dollars)
}
