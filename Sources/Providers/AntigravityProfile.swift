import CryptoKit
import Foundation

/// One Google Antigravity configuration directory, and so one account.
///
/// Discovers:
/// 1. The default `~/.gemini/antigravity`
/// 2. Any `~/.gemini/antigravity-<slug>` profile directories
/// 3. Any isolated T3 Code Antigravity provider instances under
///    `~/.t3/userdata/providers/antigravity/<sha256(instanceID)>/antigravity-acp`
///    (indexed via `~/.t3/userdata/settings.json` when available)
struct AntigravityProfile: Equatable, Hashable {
    /// The provider id the default profile has always had (`gemini`). Kept so archived
    /// readings, connection choices, and user preferences survive the change.
    static let defaultID = "gemini"
    /// What every profile directory under `~/.gemini` starts with.
    static let directoryPrefix = "antigravity"
    /// Slug prefix used for T3 Code isolated Antigravity profiles.
    static let t3SlugPrefix = "t3-"

    /// Internal tool flavours under `~/.gemini` that belong to the default installation
    /// rather than separate user accounts.
    static let ignoredSlugs: Set<String> = ["ide", "cli", "backup", "api", "acp"]

    /// Nil for `~/.gemini/antigravity`; the part after `antigravity-` otherwise.
    let slug: String?
    let configDirectory: URL
    /// Optional custom display name (for example from T3 Code's `providerInstances`).
    let customDisplayName: String?
    /// Optional isolated `antigravity-oauth-token` file used with official `agy -p /usage`.
    let cliTokenFileURL: URL?
    /// Optional account identifier (such as email) extracted from T3 Code metadata.
    let accountHint: String?
    /// Whether this profile was discovered from T3 Code's isolated provider storage.
    let isT3CodeProfile: Bool

    init(slug: String?,
         configDirectory: URL,
         customDisplayName: String? = nil,
         cliTokenFileURL: URL? = nil,
         accountHint: String? = nil,
         isT3CodeProfile: Bool = false) {
        self.slug = slug
        self.configDirectory = configDirectory
        self.customDisplayName = customDisplayName
        self.cliTokenFileURL = cliTokenFileURL
        self.accountHint = accountHint
        self.isT3CodeProfile = isT3CodeProfile
    }

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// `~/.gemini/antigravity`, whether or not it exists — the app has always read it.
    static func `default`(home: URL = homeDirectory) -> AntigravityProfile {
        let dir = home.appendingPathComponent(".gemini").appendingPathComponent(directoryPrefix)
        return AntigravityProfile(slug: nil, configDirectory: dir)
    }

    /// The default profile followed by every `~/.gemini/antigravity-<slug>` that contains
    /// profile markers and valid credentials (alphabetical), followed by any isolated
    /// T3 Code Antigravity profiles with a saved `antigravity-oauth-token`.
    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default,
                         hasCredential: (AntigravityProfile) -> Bool = AntigravityCredentials.hasCredential) -> [AntigravityProfile] {
        let geminiDir = home.appendingPathComponent(".gemini")
        let names = (try? fileManager.contentsOfDirectory(atPath: geminiDir.path)) ?? []
        let extras = names.compactMap { name -> AntigravityProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = geminiDir.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            let candidate = AntigravityProfile(slug: slug, configDirectory: directory)
            guard hasCredential(candidate) else { return nil }
            return candidate
        }
        let t3Profiles = discoverT3Profiles(home: home, fileManager: fileManager)
            .filter { hasCredential($0) }
        return [.default(home: home)]
            + extras.sorted { $0.slug! < $1.slug! }
            + t3Profiles
    }

    /// Discovers isolated T3 Code Antigravity provider instances stored under
    /// `<home>/.t3/userdata/providers/antigravity/<sha256>/antigravity-acp`.
    static func discoverT3Profiles(home: URL = homeDirectory,
                                   fileManager: FileManager = .default) -> [AntigravityProfile] {
        let userdataDir = home.appendingPathComponent(".t3/userdata")
        let providersRoot = userdataDir.appendingPathComponent("providers/antigravity")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: providersRoot.path, isDirectory: &isDir),
              isDir.boolValue else { return [] }

        var profiles: [AntigravityProfile] = []
        var matchedHashes: Set<String> = []

        // 1. Read T3 Code's settings.json to get human-readable instance IDs and display names.
        let settingsURL = userdataDir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let instances = root["providerInstances"] as? [String: [String: Any]] {
            let sortedInstanceIDs = instances.keys.sorted()
            for instanceID in sortedInstanceIDs {
                guard let config = instances[instanceID] else { continue }
                let driver = (config["driver"] as? String) ?? (config["provider"] as? String)
                guard driver == "antigravity" || instanceID == "antigravity" || instanceID.hasPrefix("antigravity_") else {
                    continue
                }
                let hash = sha256Hex(instanceID)
                // Mark as known before checking `enabled`, so disabled instances in
                // settings.json are not re-added by the fallback directory scan.
                matchedHashes.insert(hash)
                if let enabled = config["enabled"] as? Bool, !enabled { continue }

                let acpDir = providersRoot
                    .appendingPathComponent(hash)
                    .appendingPathComponent("antigravity-acp")
                let tokenURL = acpDir.appendingPathComponent("antigravity-oauth-token")
                guard fileManager.fileExists(atPath: tokenURL.path) else { continue }
                let rawDisplayName = (config["displayName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let (formattedDisplayName, accountHint) = formatT3Names(
                    instanceID: instanceID,
                    rawDisplayName: rawDisplayName
                )
                let slug = t3SlugPrefix + sanitizeSlug(instanceID)
                profiles.append(AntigravityProfile(
                    slug: slug,
                    configDirectory: acpDir,
                    customDisplayName: formattedDisplayName,
                    cliTokenFileURL: tokenURL,
                    accountHint: accountHint,
                    isT3CodeProfile: true
                ))
            }
        }

        // 2. Fallback: discover any additional T3 profile directories with a token file
        // that were not listed in settings.json.
        let entries = ((try? fileManager.contentsOfDirectory(atPath: providersRoot.path)) ?? []).sorted()
        for entry in entries where !matchedHashes.contains(entry) {
            let acpDir = providersRoot
                .appendingPathComponent(entry)
                .appendingPathComponent("antigravity-acp")
            let tokenURL = acpDir.appendingPathComponent("antigravity-oauth-token")
            guard fileManager.fileExists(atPath: tokenURL.path) else { continue }
            let shortHash = String(entry.prefix(8))
            profiles.append(AntigravityProfile(
                slug: t3SlugPrefix + sanitizeSlug(shortHash),
                configDirectory: acpDir,
                customDisplayName: "Antigravity (T3 \(shortHash))",
                cliTokenFileURL: tokenURL,
                accountHint: "T3 \(shortHash)",
                isT3CodeProfile: true
            ))
        }

        return profiles
    }

    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeSlug(_ raw: String) -> String {
        let cleaned = raw.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")) ? ch : "-"
        }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "account" : result
    }

    private static func formatT3Names(instanceID: String, rawDisplayName: String?) -> (displayName: String, accountHint: String) {
        guard let raw = rawDisplayName, !raw.isEmpty else {
            return ("Antigravity (\(instanceID))", instanceID)
        }
        var stripped = raw
        for prefix in ["Antigravity-", "Antigravity ", "antigravity-", "antigravity "] {
            if stripped.hasPrefix(prefix) {
                stripped = String(stripped.dropFirst(prefix.count))
                break
            }
        }
        let label = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            return ("Antigravity (\(instanceID))", instanceID)
        }
        // If the T3 display name embeds an email, show its local part in the compact
        // ring title and keep the full email as the account label in Settings.
        if let atIndex = label.firstIndex(of: "@"), atIndex > label.startIndex {
            let shortName = String(label[..<atIndex])
            return ("Antigravity (\(shortName))", label)
        }
        return ("Antigravity (\(label))", label)
    }

    /// `antigravity-work` -> `work`; anything else -> nil. The bare `antigravity` is
    /// the default and is handled separately. Internal flavours (`ide`, `cli`, `backup`, `api`, `acp`)
    /// are ignored unless explicit.
    static func slug(fromDirectoryName name: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let slug = String(name.dropFirst(prefix.count))
        guard !slug.isEmpty, !ignoredSlugs.contains(slug) else { return nil }
        return slug
    }

    /// Markers identifying an Antigravity configuration/profile directory.
    private static let markers = [
        "oauth_creds.json",
        "credentials.json",
        "antigravity-oauth-token",
        "brain",
        "agent.db"
    ]

    static func isProfileDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return markers.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - Identity

    /// `gemini` for the default, `antigravity-<slug>` for the rest.
    var id: String { slug.map { "\(Self.directoryPrefix)-\($0)" } ?? Self.defaultID }

    /// `Antigravity`, or `Antigravity (work)`, or T3 Code's formatted instance name.
    var displayName: String {
        if let customDisplayName, !customDisplayName.isEmpty {
            return customDisplayName
        }
        return slug.map { "Antigravity (\($0))" } ?? "Antigravity"
    }

    /// Whether a provider id names an Antigravity profile, default or otherwise.
    static func isAntigravity(providerID: String) -> Bool {
        providerID == defaultID || (providerID.hasPrefix(directoryPrefix + "-") && slug(fromProviderID: providerID) != nil)
    }

    /// Whether a provider id belongs to an isolated T3 Code Antigravity profile.
    static func isT3Code(providerID: String) -> Bool {
        guard let slug = slug(fromProviderID: providerID) else { return false }
        return slug.hasPrefix(t3SlugPrefix)
    }

    /// The slug back out of a provider id.
    static func slug(fromProviderID id: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    var authURL: URL { configDirectory.appendingPathComponent("oauth_creds.json") }
    var brainDirectory: URL { configDirectory.appendingPathComponent("brain") }

    var keychainService: String? { slug == nil ? "gemini" : nil }
    var keychainAccount: String? { slug == nil ? "antigravity" : nil }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = configDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var sourceName: String {
        if isT3CodeProfile {
            return "T3 Code · agy CLI"
        }
        guard slug != nil else { return "Antigravity" }
        return L10n.t("Antigravity in \(displayPath)")
    }

    var signInRoute: SignInRoute {
        if isT3CodeProfile {
            return .guidance(L10n.t("Sign in to this Antigravity account in T3 Code to read your usage"))
        }
        guard let slug else {
            return .openApp(bundleID: "com.google.antigravity", name: "Antigravity")
        }
        return .guidance(L10n.t("Sign in to Antigravity in ~/.gemini/antigravity-\(slug) to read your usage"))
    }
}
