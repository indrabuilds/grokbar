import AppKit
import Foundation

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var identity: AuthIdentity?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var serviceStatus: ServiceStatusSnapshot?
    /// When the shown pool figure was fetched (live or from cache).
    @Published private(set) var lastUpdatedAt: Date?

    // The separate SuperGrok / Grok Bot / Cursor toggles are gone: under the X
    // Subscription they share one pool, read from the Grok session alone.
    // Old `showGrokUsage` / `showGrokBotUsage` / `showCursorUsage` defaults are
    // left untouched and simply ignored.

    private var fetchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var didStart = false
    private var lastFetchAttemptAt: Date?
    private var consecutiveFailures = 0
    /// Automatic fetches wait until this time (error backoff / Retry-After).
    private var notBefore: Date?
    private var isAsleep = false
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Background poll while healthy. One small authenticated GET (+ 3 optional)
    /// to cli-chat-proxy every 90 s keeps the bar close to live without hammering it.
    private let pollInterval: TimeInterval = 90
    /// Opening the popover refreshes unless the last attempt was this recent.
    private let panelMinGap: TimeInterval = 30
    private let maxBackoff: TimeInterval = 15 * 60
    private let maxRetryAfter: TimeInterval = 60 * 60

    @Published private(set) var clockTick: Date = Date()

    init() {}

    var hasActiveOutage: Bool {
        serviceStatus?.hasActiveIncident == true
    }

    var menuBarAccessibilityLabel: String {
        _ = clockTick
        var parts: [String] = []
        if let status = serviceStatus, status.hasActiveIncident {
            parts.append("xAI status issue: \(status.headline)")
        }
        switch state {
        case .loaded(let snap):
            let reset = formatCountdown(snap.resetsIn) ?? "unknown"
            parts.append(
                "Usage \(Int(snap.usedPercent.rounded()))% used, \(snap.cycleLabel.lowercased()) pool, resets in \(reset)"
            )
        case .unavailable(let title, let hint):
            parts.append("Grok: \(title). \(hint)")
        case .failed(let message):
            parts.append("Usage error: \(message)")
        case .idle, .loading:
            parts.append("GrokBar. Loading usage.")
        }
        return parts.joined(separator: ". ")
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        LoginItemService.ensureEnabled()
        loadCacheIntoState()
        observeSleepAndWake()
        refreshAutomatically()
        scheduleBackgroundPoll()
        scheduleClockTick()
    }

    /// Always refresh on open, at most once per `panelMinGap`.
    func panelDidOpen() {
        start()
        if let last = lastFetchAttemptAt, Date().timeIntervalSince(last) < panelMinGap { return }
        refreshAutomatically()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        isRefreshing = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    /// Refresh button: always fetches unless a fetch is already in flight.
    func refresh() {
        runFetch()
    }

    /// Poll / popover / wake: respects sleep, error backoff and Retry-After.
    private func refreshAutomatically() {
        if isAsleep { return }
        if let notBefore, notBefore > Date() { return }
        runFetch()
    }

    private func runFetch() {
        if isRefreshing { return }

        if case .idle = state {
            state = .loading
        } else if case .failed = state {
            state = .loading
        }

        isRefreshing = true
        lastFetchAttemptAt = Date()

        fetchTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.fetchInBackground()
            }.value

            guard let self else { return }
            // Reset here (main actor) on every path so the button can't stay disabled.
            self.isRefreshing = false
            self.fetchTask = nil
            guard !Task.isCancelled else { return }
            self.apply(result: result)
        }
    }

    private func loadCacheIntoState() {
        guard let cached = UsageCache.load() else { return }
        if identity == nil, let email = cached.email {
            identity = AuthIdentity(
                email: email,
                teamID: nil,
                principalType: nil,
                authMode: nil,
                accessToken: "",
                expiresAt: nil,
                tier: cached.snapshot.subscriptionTier
            )
        }
        if case .loaded = state { return }
        state = .loaded(cached.snapshot)
        lastUpdatedAt = cached.snapshot.fetchedAt
    }

    private func apply(result: CombinedFetch) {
        if let status = result.serviceStatus {
            self.serviceStatus = status
        }

        switch result.usage {
        case .success(let (identity, snapshot)):
            self.identity = identity
            self.state = .loaded(snapshot)
            self.lastError = nil
            self.lastUpdatedAt = snapshot.fetchedAt
            consecutiveFailures = 0
            notBefore = nil
            UsageCache.save(snapshot, email: identity.email)

        case .failure(let error):
            let classified = classify(error, outage: result.serviceStatus)
            self.lastError = classified.menuMessage

            switch classified.kind {
            case .setup:
                // Local sign-in problem: keep polling at the normal pace so a new
                // `grok login` is picked up quickly.
                self.identity = nil
                self.state = .unavailable(title: classified.menuMessage, hint: classified.hint)
                self.lastUpdatedAt = nil
                UsageCache.clear()
                consecutiveFailures = 0
                notBefore = nil

            case .transient, .hard:
                if case .loaded = state {
                    // keep last good figure
                } else {
                    state = .failed(classified.menuMessage)
                }
                consecutiveFailures += 1
                var wait = min(maxBackoff, pollInterval * pow(2.0, Double(consecutiveFailures - 1)))
                if let retryAfter = (error as? UsageFetcherError)?.retryAfter {
                    wait = max(wait, min(retryAfter, maxRetryAfter))
                }
                notBefore = Date().addingTimeInterval(wait)
            }
        }
    }

    private enum FailureKind {
        case setup
        case transient
        case hard
    }

    private struct ClassifiedError {
        var kind: FailureKind
        var menuMessage: String
        var hint: String
    }

    private func classify(_ error: Error, outage: ServiceStatusSnapshot?) -> ClassifiedError {
        let outageHint: String? = {
            guard let outage, outage.hasActiveIncident else { return nil }
            return "xAI status: \(outage.headline). See status.x.ai"
        }()

        if let auth = error as? AuthStoreError {
            var hint = auth.recoveryHint
            if let outageHint, !auth.isSetupIssue {
                hint = outageHint
            }
            return ClassifiedError(
                kind: auth.isSetupIssue ? .setup : .transient,
                menuMessage: auth.errorDescription ?? "Not signed in to Grok.",
                hint: hint
            )
        }
        if let fetch = error as? UsageFetcherError {
            if fetch.isAuthIssue {
                return ClassifiedError(
                    kind: .setup,
                    menuMessage: "Grok session expired.",
                    hint: "Run `grok login` again. GrokBar will recover on the next check."
                )
            }
            if fetch.isTransient {
                return ClassifiedError(
                    kind: .transient,
                    menuMessage: outageHint != nil
                        ? "Usage unreachable (possible outage)."
                        : (fetch.errorDescription ?? "Network error."),
                    hint: outageHint ?? "Will retry automatically."
                )
            }
            return ClassifiedError(
                kind: .hard,
                menuMessage: fetch.errorDescription ?? "Couldn’t load usage.",
                hint: outageHint ?? "Will retry automatically."
            )
        }
        return ClassifiedError(
            kind: .transient,
            menuMessage: error.localizedDescription,
            hint: outageHint ?? "Will retry automatically."
        )
    }

    private struct CombinedFetch: @unchecked Sendable {
        var usage: Result<(AuthIdentity, UsageSnapshot), Error>
        var serviceStatus: ServiceStatusSnapshot?
    }

    /// Grok session only (`~/.grok/auth.json` + cli-chat-proxy). No Cursor login needed.
    private nonisolated static func fetchInBackground() async -> CombinedFetch {
        async let statusTask: ServiceStatusSnapshot? = {
            try? await StatusFetcher.fetch()
        }()
        let usage = await fetchGrok()
        let status = await statusTask
        return CombinedFetch(usage: usage, serviceStatus: status)
    }

    private nonisolated static func fetchGrok() async -> Result<(AuthIdentity, UsageSnapshot), Error> {
        do {
            var identity = try await AuthStore.loadValidIdentity()
            do {
                let snapshot = try await UsageFetcher.fetch(
                    token: identity.accessToken,
                    subscriptionTier: identity.tier
                )
                return .success((identity, snapshot))
            } catch let fetch as UsageFetcherError {
                if case .unauthorized = fetch {
                    do {
                        let cred = try AuthStore.loadCredential()
                        let refreshed = try await AuthStore.refreshCredential(cred)
                        identity = refreshed.identity
                        let snapshot = try await UsageFetcher.fetch(
                            token: identity.accessToken,
                            subscriptionTier: identity.tier
                        )
                        return .success((identity, snapshot))
                    } catch let auth as AuthStoreError {
                        return .failure(auth)
                    } catch {
                        return .failure(AuthStoreError.sessionExpired)
                    }
                }
                return .failure(fetch)
            }
        } catch {
            return .failure(error)
        }
    }

    func openUsagePage() {
        if let url = URL(string: "https://grok.com/?_s=usage") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBillingPage() {
        if let url = URL(string: "https://grok.com/?_s=billing") {
            NSWorkspace.shared.open(url)
        }
    }

    func openStatusPage() {
        if let link = serviceStatus?.activeIncidents.first?.link {
            NSWorkspace.shared.open(link)
            return
        }
        NSWorkspace.shared.open(StatusFetcher.statusPageURL)
    }

    func quit() {
        stop()
        NSApp.terminate(nil)
    }

    private var nextPollDelay: TimeInterval {
        if let notBefore {
            let remaining = notBefore.timeIntervalSinceNow
            if remaining > 0 { return max(1, remaining) }
        }
        return pollInterval
    }

    private func scheduleBackgroundPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = await MainActor.run { self?.nextPollDelay ?? 90 }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.refreshAutomatically()
            }
        }
    }

    /// Pause polling while the Mac sleeps; refresh as soon as it wakes.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAsleep = true
                self.pollTask?.cancel()
                self.pollTask = nil
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAsleep = false
                self.refreshAutomatically()
                self.scheduleBackgroundPoll()
            }
        })
    }

    private func scheduleClockTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.clockTick = Date()
            }
        }
    }
}
