import XCTest
@testable import Codenotch

final class AntigravityCLIUsageTests: XCTestCase {
    private let realAgyUsageJSON = Data("""
    {
      "conversation_id": "",
      "status": "SUCCESS",
      "response": "Gemini Models\\tWeekly Limit Remaining\\t69%\\t2026-12-01T01:54:03Z\\n",
      "duration_seconds": 0,
      "num_turns": 0,
      "command": {
        "name": "usage",
        "data": {
          "description": "Within each group, models share a weekly limit and a 5-hour limit.",
          "groups": [
            {
              "name": "Gemini Models",
              "buckets": [
                {
                  "id": "gemini-weekly",
                  "name": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remaining_fraction": 0.6851396560668945,
                  "reset_time": "2026-12-01T01:54:03Z"
                },
                {
                  "id": "gemini-5h",
                  "name": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remaining_fraction": 0.9457110166549683,
                  "reset_time": "2026-11-26T06:35:09Z"
                }
              ]
            },
            {
              "name": "Claude and GPT models",
              "buckets": [
                {
                  "id": "3p-weekly",
                  "name": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remaining_fraction": 1,
                  "reset_time": "1970-01-01T00:00:00Z"
                },
                {
                  "id": "3p-5h",
                  "name": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remaining_fraction": 1,
                  "reset_time": "1970-01-01T00:00:00Z"
                }
              ]
            }
          ]
        }
      }
    }
    """.utf8)

    func testParsesOfficialAgyPrintUsageJSON() {
        let windows = AntigravityQuotaParser.parse(realAgyUsageJSON, now: Date())
        XCTAssertEqual(windows.map(\.id), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])

        let gemini5h = windows.first { $0.id == "gemini-5h" }
        XCTAssertEqual(gemini5h?.group, L10n.t("Gemini Models"))
        XCTAssertEqual(gemini5h?.label, L10n.t("5-hour Limit"))
        XCTAssertEqual(gemini5h?.usedFraction ?? -1, 1 - 0.9457110166549683, accuracy: 0.0001)
        XCTAssertNotNil(gemini5h?.resetsAt)
        XCTAssertEqual(gemini5h?.duration, 5 * 3600)

        let geminiWeekly = windows.first { $0.id == "gemini-weekly" }
        XCTAssertEqual(geminiWeekly?.usedFraction ?? -1, 1 - 0.6851396560668945, accuracy: 0.0001)
        XCTAssertNotNil(geminiWeekly?.resetsAt)
        XCTAssertEqual(geminiWeekly?.duration, 7 * 86400)

        // Epoch-zero reset times on untouched 100% buckets must become nil.
        let thirdParty5h = windows.first { $0.id == "3p-5h" }
        XCTAssertEqual(thirdParty5h?.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(thirdParty5h?.resetsAt)
    }

    func testDiscoversT3CodeProfilesFromSettingsAndTokens() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("T3AntigravityTests.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let userdata = root.appendingPathComponent(".t3/userdata")
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)

        let settings = """
        {
          "providerInstances": {
            "antigravity": {
              "driver": "antigravity",
              "displayName": "Antigravity-alice@example.com",
              "enabled": true
            },
            "antigravity_2": {
              "driver": "antigravity",
              "displayName": "Antigravity-bob@example.com",
              "enabled": true
            },
            "antigravity_disabled": {
              "driver": "antigravity",
              "displayName": "Antigravity-disabled@example.com",
              "enabled": false
            }
          }
        }
        """
        try settings.data(using: .utf8)!.write(to: userdata.appendingPathComponent("settings.json"))

        for id in ["antigravity", "antigravity_2", "antigravity_disabled"] {
            let hash = AntigravityProfile.sha256Hex(id)
            let acpDir = userdata
                .appendingPathComponent("providers/antigravity/\(hash)/antigravity-acp")
            try FileManager.default.createDirectory(at: acpDir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: acpDir.appendingPathComponent("antigravity-oauth-token"))
        }

        let found = AntigravityProfile.discover(home: root)
        let t3 = found.filter(\.isT3CodeProfile)
        XCTAssertEqual(t3.map(\.id), ["antigravity-t3-antigravity", "antigravity-t3-antigravity_2"])
        XCTAssertEqual(t3.map(\.displayName), ["Antigravity (alice)", "Antigravity (bob)"])
        XCTAssertEqual(t3.map(\.accountHint), ["alice@example.com", "bob@example.com"])
        XCTAssertTrue(t3.allSatisfy { $0.cliTokenFileURL != nil })
        XCTAssertTrue(Preferences.isDefaultOnFamily("antigravity-t3-antigravity"))
        XCTAssertTrue(AntigravityProfile.isAntigravity(providerID: "antigravity-t3-antigravity"))
    }

    func testScopedCLIEnvironmentForcesFileStorageAndStubsBrowser() {
        let stubBin = URL(fileURLWithPath: "/tmp/codenotch-test-bin")
        let home = URL(fileURLWithPath: "/tmp/codenotch-test-home")
        let tmp = URL(fileURLWithPath: "/tmp/codenotch-test-tmp")

        let env = AntigravityCLIUsageFetcher.buildEnvironment(
            base: [
                "PATH": "/usr/bin:/bin",
                "SECRET_TOKEN": "must-not-leak",
                "HTTPS_PROXY": "http://127.0.0.1:7890",
            ],
            stubBinDirectory: stubBin,
            isolatedHome: home,
            tempDirectory: tmp
        )

        XCTAssertEqual(env["HOME"], home.path)
        XCTAssertEqual(env["GEMINI_HOME"], home.appendingPathComponent(".gemini").path)
        XCTAssertEqual(env["AGY_CLI_FORCE_FILE_TOKEN_STORAGE"], "1")
        XCTAssertEqual(env["AGY_CLI_DISABLE_AUTO_UPDATE"], "true")
        XCTAssertEqual(env["BROWSER"], stubBin.appendingPathComponent("open").path)
        XCTAssertTrue(env["PATH"]?.hasPrefix(stubBin.path + ":") == true)
        XCTAssertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7890")
        XCTAssertNil(env["SECRET_TOKEN"])
    }

    func testProviderCachesCLIQuotaAndBypassesCacheOnFromSource() async throws {
        let profile = AntigravityProfile(
            slug: "t3-antigravity",
            configDirectory: URL(fileURLWithPath: "/tmp/t3-test/antigravity-acp"),
            customDisplayName: "Antigravity (alice)",
            cliTokenFileURL: URL(fileURLWithPath: "/tmp/t3-test/antigravity-acp/antigravity-oauth-token"),
            accountHint: "alice@example.com",
            isT3CodeProfile: true
        )

        let counter = InvocationCounter()
        let provider = AntigravityProvider(
            profile: profile,
            cliQuota: { _ in
                let call = counter.increment()
                return [
                    LimitWindow(id: "gemini-5h", group: "Gemini Models", label: "5-hour Limit", usedFraction: 0.1 * Double(call)),
                    LimitWindow(id: "gemini-weekly", group: "Gemini Models", label: "Weekly Limit", usedFraction: 0.3),
                ]
            }
        )

        let first = try await provider.fetchSnapshot(freshness: .standard)
        XCTAssertEqual(first.fidelity, .official)
        XCTAssertEqual(counter.value, 1)

        // Subsequent .standard fetch within TTL returns cached result without respawning CLI.
        let cached = try await provider.fetchSnapshot(freshness: .standard)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(cached.windows.first { $0.id == "gemini-5h" }?.usedFraction ?? -1, 0.1, accuracy: 0.0001)

        // Manual .fromSource refresh bypasses the cache.
        let fresh = try await provider.fetchSnapshot(freshness: .fromSource)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(fresh.windows.first { $0.id == "gemini-5h" }?.usedFraction ?? -1, 0.2, accuracy: 0.0001)
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
