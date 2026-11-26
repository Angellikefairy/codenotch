import Foundation
import SQLite3
import os
/// Gemini, as Antigravity sees it.
///
/// **What this can and cannot report, and why.** Antigravity talks to Google's
/// Cloud Code backend, and the only call that describes the account is
/// `:loadCodeAssist`. It answers with tiers — which plan you are on and which
/// you are not eligible for — and no numbers: no used, no limit, no reset. A
/// packet capture of a signed-in install showed exactly two RPCs, and neither
/// carries a quota.
///
/// So this provider reports the account honestly and says there is nothing
/// metered, rather than inventing a ring. That is the same answer Cursor's free
/// plan gets, and for the same reason: a confident 0% is worse than an admitted
/// blank, especially in something people pay for.
actor AntigravityProvider: UsageProvider {
    nonisolated let profile: AntigravityProfile
    nonisolated let id: String
    // The id stays `gemini` for default profile: it keys the archive and the user's connection
    // choice, and changing it would silently discard both. Additional profiles are `antigravity-<slug>`.
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.antigravity

    private let session: URLSession
    /// A second session, trusting loopback only, for the local language server.
    private let localSession: URLSession
    /// Re-discovering the port and token means spawning `ps` and `lsof`, which
    /// is not something to do every minute. Cached until it stops working.
    private var bridge: AntigravityBridge.Endpoint?
    /// Whether the language server has ever answered.
    ///
    /// Once it has, a failure is Antigravity being closed or restarted — its
    /// port changes every launch — not an account that cannot be read. Falling
    /// back to the request count then *replaces* a percentage with a plain
    /// number, and a ring that reads 8% one minute and 31 the next looks broken
    /// rather than degraded.
    private var everBridged = false
    /// Cached official `agy -p /usage` windows so frequent background ticks do
    /// not respawn the CLI every 30 seconds.
    private var cachedCLIWindows: (windows: [LimitWindow], fetchedAt: Date)?
    private var lastCLIFailureAt: Date?

    /// Cache windows for official `agy -p /usage` invocations.
    static let standardCLICacheTTL: TimeInterval = 5 * 60
    static let liveCLICacheTTL: TimeInterval = 2 * 60
    static let cliFailureCooldown: TimeInterval = 60

    /// How the language server is asked, when a test needs to say. Production
    /// leaves this nil and goes through `localQuota()`, which spawns `ps` and
    /// `lsof` to find a port that only exists while Antigravity is running —
    /// nothing a test can arrange, and the ordering this fixes is exactly what
    /// would otherwise go uncovered.
    private let localQuotaOverride: (@Sendable () async -> [LimitWindow]?)?
    /// Injectable official `agy -p /usage` fetcher for unit testing.
    private let cliQuotaOverride: (@Sendable (AntigravityProfile) async throws -> [LimitWindow])?

    init(profile: AntigravityProfile = .default(),
         session: URLSession = .shared,
         localQuota: (@Sendable () async -> [LimitWindow]?)? = nil,
         cliQuota: (@Sendable (AntigravityProfile) async throws -> [LimitWindow])? = nil) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.session = session
        self.localQuotaOverride = localQuota
        self.cliQuotaOverride = cliQuota
        self.localSession = URLSession(configuration: .ephemeral,
                                       delegate: LocalhostTrust(),
                                       delegateQueue: nil)
    }

    nonisolated var signInRoute: SignInRoute {
        profile.signInRoute
    }

    /// Reached only from "Allow access…", so it may let the next read prompt.
    nonisolated func forgetCachedCredential() {
        AntigravityCredentials.forgetCached(for: profile)
        AntigravityCredentials.askAgain(for: profile)
    }

    nonisolated func account() -> ProviderAccount? {
        if profile.isT3CodeProfile {
            return ProviderAccount(
                label: profile.accountHint ?? profile.displayName,
                plan: "T3 Code",
                source: profile.sourceName,
                manageURL: URL(string: "https://antigravity.google")
            )
        }

        if AntigravityCredentials.isSignedIn(for: profile), let held = AntigravityCredentials.held(for: profile) {
            let email = held.email
            let plan = held.authMethod == "consumer" ? L10n.t("Personal") : held.authMethod
            let source = held.sourceName ?? profile.sourceName
            return ProviderAccount(
                label: email,
                plan: plan,
                source: source,
                manageURL: URL(string: "https://antigravity.google")
            )
        }

        if profile.slug == nil && UserDefaults.standard.bool(forKey: "AntigravityEverBridged") {
            return ProviderAccount(
                label: L10n.t("Local Session"),
                plan: L10n.t("Active"),
                source: "agy CLI / Antigravity",
                manageURL: URL(string: "https://antigravity.google")
            )
        }

        return nil
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        try await fetchSnapshot(freshness: .standard)
    }

    func fetchSnapshot(freshness: UsageFreshness) async throws -> ProviderSnapshot {
        // 1. Default profile: if the Antigravity IDE language server is already
        // running locally (or injected in tests), read its local loopback summary.
        // Never calls Google's internal `v1internal` APIs directly.
        if profile.slug == nil {
            if let bridged = await localQuota(), !bridged.isEmpty {
                everBridged = true
                UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")
                let preferred = Preferences.storedAntigravityHeadlineModel().rawValue
                // If the local IDE server already covers the selected model family
                // (or in unit tests with a mock localQuota), return it directly.
                if localQuotaOverride != nil || bridged.contains(where: { $0.id.hasPrefix(preferred) }) {
                    return officialSnapshot(bridged)
                }
                // Otherwise complete with official `agy -p /usage` (which returns
                // both Gemini and Claude/GPT groups) without touching v1internal.
                if let cliWindows = await fetchCLIQuota(freshness: freshness), !cliWindows.isEmpty {
                    return officialSnapshot(Self.union(bridged, cliWindows))
                }
                return officialSnapshot(bridged)
            }

            if localQuotaOverride != nil && everBridged {
                throw UsageProviderError.credentialExpired
            }
        }

        // 2. Official `agy -p /usage --output-format json` path:
        //    - For T3 Code profiles (and any profile with an `antigravity-oauth-token`),
        //      runs `agy` in an isolated temporary HOME with AGY_CLI_FORCE_FILE_TOKEN_STORAGE=1.
        //    - For the default profile, runs `agy` against the ambient CLI sign-in.
        //    Never calls `cloudcode-pa.googleapis.com/v1internal` or refreshes tokens directly.
        if let cliWindows = await fetchCLIQuota(freshness: freshness), !cliWindows.isEmpty {
            if profile.slug == nil {
                everBridged = true
                UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")
            }
            return officialSnapshot(cliWindows)
        }

        // If we had a recent official CLI reading and a manual/live refresh failed,
        // keep the last good official reading rather than replacing percentages with
        // a bare request count.
        if let cached = cachedCLIWindows, !cached.windows.isEmpty {
            let chosen = selection(for: cached.windows)
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .stale(since: cached.fetchedAt),
                                    windows: chosen.windows,
                                    headlineID: chosen.headlineID,
                                    weeklyID: chosen.weeklyID)
        }

        // 3. Fallback to OMP SQLite store if offline (read-only local DB, no network).
        if profile.slug == nil {
            let omp = Self.ompUsage(forEmail: AntigravityCredentials.held(for: profile)?.email)
            if !omp.windows.isEmpty {
                let chosen = selection(for: omp.windows)
                var status = ProviderStatus.ok
                if let recordedAt = omp.recordedAt, Date().timeIntervalSince(recordedAt) > Self.ompFreshness {
                    status = .stale(since: recordedAt)
                }
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: status, windows: chosen.windows,
                                        headlineID: chosen.headlineID,
                                        weeklyID: chosen.weeklyID)
            }
        }

        if everBridged { throw UsageProviderError.credentialExpired }

        // 4. Final fallback: local transcript request count (offline, no network).
        let roots = profile.slug == nil ? AntigravityActivity.transcriptRoots : [profile.brainDirectory]
        let activity = AntigravityActivity.read(roots: roots)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: [
                LimitWindow(id: "requests",
                            label: activity.label(),
                            used: activity.requestsToday)
            ],
            headlineID: "requests"
        )
    }

    private func fetchCLIQuota(freshness: UsageFreshness) async -> [LimitWindow]? {
        let now = Date()
        if freshness != .fromSource, let cached = cachedCLIWindows {
            let ttl = freshness == .live ? Self.liveCLICacheTTL : Self.standardCLICacheTTL
            if now.timeIntervalSince(cached.fetchedAt) < ttl {
                return cached.windows
            }
        }
        if freshness != .fromSource, let failedAt = lastCLIFailureAt,
           now.timeIntervalSince(failedAt) < Self.cliFailureCooldown {
            return cachedCLIWindows?.windows
        }

        let tokenURL = profile.cliTokenFileURL ?? {
            guard profile.slug != nil else { return nil }
            let candidate = profile.configDirectory.appendingPathComponent("antigravity-oauth-token")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }()

        // Non-default profiles without a CLI token file cannot be queried via `agy`.
        if profile.slug != nil && tokenURL == nil && cliQuotaOverride == nil {
            return nil
        }

        do {
            let windows: [LimitWindow]
            if let cliQuotaOverride {
                windows = try await cliQuotaOverride(profile)
            } else {
                windows = try await AntigravityCLIUsageFetcher.fetchWindows(tokenFileURL: tokenURL)
            }
            guard !windows.isEmpty else {
                lastCLIFailureAt = Date()
                return nil
            }
            cachedCLIWindows = (windows, Date())
            lastCLIFailureAt = nil
            return windows
        } catch {
            lastCLIFailureAt = Date()
            Log.usage.debug("Antigravity CLI usage failed for \(self.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    nonisolated func resolveHeadlineID(for windows: [LimitWindow]) -> String {
        let preferredLimit = Preferences.storedAntigravityHeadlineLimit()
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        // Only the chosen family. It used to fall back to every window when
        // this came up empty, which reported a different allowance under the
        // name of the one that was asked for — the reader chose Gemini, the
        // account had no Gemini group, and the ring showed the third-party
        // group's number as if it were the answer. A family that reported
        // nothing is an absent reading, not another family's reading.
        let candidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        guard !candidates.isEmpty else { return Self.unavailableWindowID }

        if preferredLimit != .automatic {
            let limitCandidates = candidates.filter { matches($0, cadence: preferredLimit) }
            if let mostConstrained = limitCandidates.max(by: constrainedBefore) {
                return mostConstrained.id
            }
        }

        // Match CodexBar's default: an exhausted lane does not displace a
        // usable lane unless every lane is exhausted.
        let fractional = candidates.filter { $0.usedFraction != nil }
        let usable = fractional.filter { ($0.usedFraction ?? 0) < 1 }
        return (usable.isEmpty ? fractional : usable).max(by: constrainedBefore)?.id
            ?? candidates.first?.id
            ?? "\(preferredModel.rawValue)-hourly"
    }

    private nonisolated func matches(_ window: LimitWindow, cadence: AntigravityHeadlineLimit) -> Bool {
        let value = "\(window.id) \(window.label)".lowercased()
        switch cadence {
        case .fiveHour:
            return window.duration == 5 * 3600 ||
                ["5h", "5-hour", "five hour", "five-hour", "hourly", "session"]
                    .contains(where: { value.contains($0) })
        case .weekly:
            return window.duration == 7 * 86400 || value.contains("weekly")
        case .automatic:
            return true
        }
    }

    private nonisolated func constrainedBefore(_ lhs: LimitWindow, _ rhs: LimitWindow) -> Bool {
        let left = lhs.usedFraction ?? 0
        let right = rhs.usedFraction ?? 0
        if left != right { return left < right }
        return lhs.id > rhs.id
    }

    nonisolated func resolveWeeklyID(for windows: [LimitWindow]) -> String? {
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        // The chosen family only, for the same reason as the headline: the
        // weekly allowance of one family is not the weekly allowance of
        // another. No weekly window in the family means no second ring.
        let candidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let weekly = candidates.filter { window in
            window.duration == 7 * 86400 ||
                window.id.lowercased().hasSuffix("-weekly") ||
                window.label.lowercased().contains("weekly")
        }
        return weekly.max(by: constrainedBefore)?.id
    }

    /// The id of the window that stands in for a family which reported nothing.
    ///
    /// Deliberately outside every family's id namespace, so that adding it to
    /// the windows does not make that family look present.
    static let unavailableWindowID = "quota-group-unavailable"

    /// The reading shown for a family that reported nothing.
    ///
    /// The reader asked for that family, so the cell says the family is not
    /// reporting rather than going quiet or, worse, showing another family's
    /// number. The other families stay in the list, so the account's other
    /// allowances remain visible.
    nonisolated static func unavailableWindow(for model: AntigravityHeadlineModel) -> LimitWindow {
        LimitWindow(id: unavailableWindowID,
                    group: model.explanation,
                    label: L10n.t("No reading"),
                    usedFraction: nil)
    }

    /// The windows to show, and which of them is the reading.
    ///
    /// A family that reported nothing gets an explicit reading of its own, so
    /// that its absence is shown rather than covered by another family.
    private nonisolated func selection(
        for windows: [LimitWindow]
    ) -> (windows: [LimitWindow], headlineID: String, weeklyID: String?) {
        let preferred = Preferences.storedAntigravityHeadlineModel()
        let reported = windows.contains { $0.id.hasPrefix(preferred.rawValue) }
        let shown = reported ? windows : windows + [Self.unavailableWindow(for: preferred)]
        return (shown, resolveHeadlineID(for: shown), resolveWeeklyID(for: shown))
    }

    /// Ask Antigravity's language server, if it is running.
    ///
    /// Returns nil rather than throwing when it is not: Antigravity being
    /// closed is the ordinary case, not a fault, and the caller has an honest
    /// answer to fall back to.
    private func localQuota(processTable: String? = nil) async -> [LimitWindow]? {
        if let localQuotaOverride { return await localQuotaOverride() }
        if let bridge {
            do {
                let windows = try await AntigravityBridge.quota(from: bridge, session: localSession)
                if !windows.isEmpty { return windows }
            } catch {
                Log.usage.debug("Antigravity cached bridge endpoint gone: \(String(describing: error), privacy: .public)")
                self.bridge = nil
            }
        }
        guard let fresh = await resolveEndpoint(processTable: processTable) else {
            Log.usage.debug("Antigravity localQuota discover failed to find process")
            return nil
        }
        self.bridge = fresh
        do {
            return try await AntigravityBridge.quota(from: fresh, session: localSession)
        } catch {
            Log.usage.debug("Antigravity localQuota fresh bridge error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Only attaches to an already-running local IDE language server; never
    /// spawns a standalone server or contacts Google's `v1internal` APIs directly.
    private func resolveEndpoint(processTable: String? = nil) async -> AntigravityBridge.Endpoint? {
        AntigravityBridge.discover(processTable: processTable)
    }

    /// A reading from any official source, with the chosen family answered
    /// from itself — see `selection(for:)`.
    private func officialSnapshot(_ windows: [LimitWindow]) -> ProviderSnapshot {
        let chosen = selection(for: windows)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: chosen.windows,
                                headlineID: chosen.headlineID,
                                weeklyID: chosen.weeklyID)
    }

    /// Union by id, the second answer winning.
    static func union(_ first: [LimitWindow], _ second: [LimitWindow]) -> [LimitWindow] {
        var merged: [LimitWindow] = []
        var indexByID: [String: Int] = [:]
        for window in first + second {
            if let existing = indexByID[window.id] {
                merged[existing] = window
            } else {
                indexByID[window.id] = merged.count
                merged.append(window)
            }
        }
        return merged
    }

    /// Turns a quota summary into standard limit windows.
    nonisolated static func windows(in data: Data, now: Date = Date()) -> [LimitWindow] {
        AntigravityQuotaParser.parse(data, now: now)
    }

    /// Where oh-my-pi (omp) keeps its credentials and its usage history.
    static let ompDatabaseURL = URL(fileURLWithPath: ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath)

    /// The last quota omp read for this account, for when nothing live answers.
    ///
    /// omp records every usage fetch in `usage_history` (`recorded_at, provider,
    /// account_key, email, account_id, limit_id, label, window_label,
    /// used_fraction, status, resets_at`, times in milliseconds). The query has
    /// to name those columns: asking for any other one fails to prepare, and the
    /// fallback then returns nothing on every Mac.
    ///
    /// `recordedAt` is when omp took the newest reading used, so the caller can
    /// say how old it is instead of passing history off as a live answer.
    ///
    /// Left out, each because it would report a number that is not this
    /// family's current one:
    /// - a row whose window has reset since omp read it, and a row with no
    ///   reset time that is more than a week old;
    /// - omp's `gemini-argon-` buckets, since Argon's weekly allowance is its
    ///   own and folding it into the Gemini slot would show Argon's number as
    ///   Gemini's;
    /// - the `default` counter, which omp uses for a quota it could not place
    ///   in any family.
    static func ompUsage(forEmail email: String? = nil,
                         databaseURL: URL = ompDatabaseURL,
                         now: Date = Date()) -> (windows: [LimitWindow], recordedAt: Date?) {
        guard let db = SQLiteStore.open(databaseURL) else { return ([], nil) }
        defer { sqlite3_close(db) }

        var targetEmail = email
        if targetEmail == nil {
            targetEmail = SQLiteStore.rows(in: db, sql: """
                SELECT email FROM usage_history
                WHERE provider = 'google-antigravity' AND email IS NOT NULL AND email != ''
                ORDER BY recorded_at DESC, id DESC LIMIT 1;
                """).first
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let weekAgoMs = nowMs - 7 * 86_400_000
        let filtered = !(targetEmail ?? "").isEmpty
        let sql = """
        SELECT limit_id, label, window_label, used_fraction, resets_at, recorded_at
        FROM usage_history
        WHERE provider = 'google-antigravity'
          AND used_fraction IS NOT NULL
          AND (resets_at > ?1 OR (resets_at IS NULL AND recorded_at > ?2))
          AND limit_id NOT LIKE '%:gemini-argon-%'\(filtered ? "\n  AND email = ?3 COLLATE NOCASE" : "")
        ORDER BY recorded_at DESC, id DESC
        LIMIT 30;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ([], nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, nowMs)
        sqlite3_bind_int64(stmt, 2, weekAgoMs)
        if filtered, let targetEmail {
            sqlite3_bind_text(stmt, 3, targetEmail, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var latestByID: [String: (window: LimitWindow, recordedAt: Int64)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let limitText = sqlite3_column_text(stmt, 0) else { continue }
            let limitID = String(cString: limitText)
            let rawLabel = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let windowLabel = sqlite3_column_text(stmt, 2).map { String(cString: $0).lowercased() } ?? ""
            let usedFraction = max(0, min(1, sqlite3_column_double(stmt, 3)))
            let resetsAtMs = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_double(stmt, 4) : 0
            let resetsAt = resetsAtMs > 0 ? Date(timeIntervalSince1970: resetsAtMs / 1000) : nil
            let recordedAt = sqlite3_column_int64(stmt, 5)

            // `google-antigravity:<counter>:<tier>:<bucket or window>`
            let parts = limitID.split(separator: ":", omittingEmptySubsequences: false)
            let counter = parts.count > 1 ? String(parts[1]) : ""
            let isGemini: Bool
            switch counter {
            case "google": isGemini = true
            case "anthropic", "openai": isGemini = false
            case "default": continue
            default:
                guard rawLabel.contains("Google") else { continue }
                isGemini = true
            }
            let isWeekly = windowLabel.contains("week")
            let id = isGemini ? (isWeekly ? "gemini-weekly" : "gemini-hourly") : (isWeekly ? "3p-weekly" : "3p-hourly")

            // Rows come newest first. One fetch can write several rows for a
            // slot (one per tier); like the live reader, the most used of
            // those is the slot's reading. An older fetch never replaces it.
            if let kept = latestByID[id] {
                guard kept.recordedAt == recordedAt, usedFraction > (kept.window.usedFraction ?? 0) else { continue }
            }
            latestByID[id] = (LimitWindow(
                id: id,
                group: isGemini ? L10n.t("Gemini Models") : L10n.t("Claude and GPT models"),
                label: isWeekly ? L10n.t("Weekly Limit") : L10n.t("5-hour Limit"),
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                // omp also files its Daily windows here, so the short slot
                // claims no length rather than a 5 hours it may not have.
                duration: isWeekly ? 7 * 86400 : nil), recordedAt)
        }

        let windows = ["gemini-hourly", "gemini-weekly", "3p-hourly", "3p-weekly"].compactMap { latestByID[$0]?.window }
        let newest = latestByID.values.map(\.recordedAt).max()
        return (windows, newest.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
    }

    /// How old an omp reading may be before it is shown as stale. omp reads
    /// usage on its own schedule, so anything older than a few refreshes is
    /// history rather than the current state.
    static let ompFreshness: TimeInterval = 10 * 60

    /// Read the plan name from `loadCodeAssist`.
    static func tier(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Gemini"
        }
        if let current = json["currentTier"] as? [String: Any],
           let name = current["name"] as? String, !name.isEmpty {
            return name
        }
        if let allowed = json["allowedTiers"] as? [[String: Any]] {
            if let def = allowed.first(where: { ($0["isDefault"] as? Bool) == true }),
               let name = def["name"] as? String, !name.isEmpty {
                return name
            }
            if let first = allowed.first,
               let name = first["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return "Gemini"
    }
}
