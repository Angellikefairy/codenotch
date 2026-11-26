import Darwin
import Foundation
import os

/// Runs the unmodified official `agy` CLI (`agy -p /usage --output-format json`)
/// in an isolated temporary directory so Codenotch never calls Google's internal
/// `cloudcode-pa.googleapis.com/v1internal` endpoints directly.
///
/// For T3 Code (and other file-token) profiles, the profile's
/// `antigravity-oauth-token` is copied into a private `0700` temporary `HOME`
/// with `AGY_CLI_FORCE_FILE_TOKEN_STORAGE=1`, keeping both the macOS Keychain
/// and T3 Code's live profile directory untouched.
enum AntigravityCLIUsageFetcher {
    enum FetchError: Error, Equatable {
        case binaryNotFound
        case tokenFileMissing
        case launchFailed
        case timedOut
        case nonZeroExit(Int32)
        case emptyQuota
    }

    static let defaultTimeout: TimeInterval = 45
    private static let maxOutputBytes = 1_048_576

    /// Well-known installation paths for the official `agy` CLI binary.
    static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> String? {
        if let explicit = environment["ANTIGRAVITY_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty
        {
            return fileManager.isExecutableFile(atPath: explicit) ? explicit : nil
        }

        let wellKnown = [
            home.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        for path in wellKnown where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        let searchPaths = (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        for dir in searchPaths where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("agy").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `agy -p /usage --output-format json` and parses the resulting
    /// `LimitWindow` list.
    ///
    /// - Parameters:
    ///   - tokenFileURL: Optional `antigravity-oauth-token` file for an isolated
    ///     account (such as a T3 Code profile). When `nil`, runs against the
    ///     ambient CLI login.
    ///   - timeout: Maximum wall-clock duration before the child process is killed.
    static func fetchWindows(
        tokenFileURL: URL? = nil,
        executablePath: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        now: Date = Date()
    ) async throws -> [LimitWindow] {
        guard let binary = executablePath ?? resolveExecutable() else {
            throw FetchError.binaryNotFound
        }
        let data = try await runPrintUsage(
            binary: binary,
            tokenFileURL: tokenFileURL,
            timeout: timeout
        )
        let windows = AntigravityQuotaParser.parse(data, now: now)
        guard !windows.isEmpty else {
            throw FetchError.emptyQuota
        }
        return windows
    }

    /// Builds the child environment for a scoped or ambient `agy -p /usage` run.
    static func buildEnvironment(
        base: [String: String],
        stubBinDirectory: URL,
        isolatedHome: URL?,
        tempDirectory: URL
    ) -> [String: String] {
        var env: [String: String] = [:]
        if isolatedHome != nil {
            let allowlisted = [
                "PATH", "LANG", "LC_ALL",
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            ]
            for key in allowlisted {
                if let value = base[key], !value.isEmpty {
                    env[key] = value
                }
            }
            if let isolatedHome {
                env["HOME"] = isolatedHome.path
                env["PWD"] = isolatedHome.path
                env["GEMINI_HOME"] = isolatedHome.appendingPathComponent(".gemini").path
                env["AGY_CLI_FORCE_FILE_TOKEN_STORAGE"] = "1"
            }
        } else {
            env = base
        }

        let basePath = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = stubBinDirectory.path + ":" + basePath
        env["BROWSER"] = stubBinDirectory.appendingPathComponent("open").path
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        env["TMPDIR"] = tempDirectory.path
        // Strip keys that could force unexpected client behavior or leak parent state.
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        env.removeValue(forKey: "CHROME_CRASHPAD_PIPE_NAME")
        return env
    }

    private static func runPrintUsage(
        binary: String,
        tokenFileURL: URL?,
        timeout: TimeInterval
    ) async throws -> Data {
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("codenotch-agy-usage-\(UUID().uuidString)", isDirectory: true)
        let binDir = stagingRoot.appendingPathComponent("bin", isDirectory: true)
        let tmpDir = stagingRoot.appendingPathComponent("tmp", isDirectory: true)

        try fm.createDirectory(at: binDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stagingRoot) }

        // Prevent `agy` from ever popping open a browser window on expired/missing sign-in.
        let stubScript = Data("#!/bin/sh\nexit 1\n".utf8)
        for cmd in ["open", "xdg-open"] {
            let stubURL = binDir.appendingPathComponent(cmd)
            guard fm.createFile(atPath: stubURL.path, contents: stubScript,
                                attributes: [.posixPermissions: 0o700]) else {
                throw FetchError.launchFailed
            }
        }

        var isolatedHome: URL?
        if let tokenFileURL {
            guard fm.fileExists(atPath: tokenFileURL.path) else {
                throw FetchError.tokenFileMissing
            }
            let homeDir = stagingRoot.appendingPathComponent("home", isDirectory: true)
            let cliDir = homeDir
                .appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent("antigravity-cli", isDirectory: true)
            try fm.createDirectory(at: cliDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let destToken = cliDir.appendingPathComponent("antigravity-oauth-token")
            let tokenData = try Data(contentsOf: tokenFileURL)
            guard fm.createFile(atPath: destToken.path, contents: tokenData,
                                attributes: [.posixPermissions: 0o600]) else {
                throw FetchError.launchFailed
            }
            isolatedHome = homeDir
        }

        let env = buildEnvironment(
            base: ProcessInfo.processInfo.environment,
            stubBinDirectory: binDir,
            isolatedHome: isolatedHome,
            tempDirectory: tmpDir
        )
        let workDir = isolatedHome ?? stagingRoot
        let timeoutSeconds = max(5, Int(timeout.rounded()))

        return try await runSubprocess(
            binary: binary,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "\(timeoutSeconds)s"],
            environment: env,
            currentDirectory: workDir,
            timeout: timeout
        )
    }

    private static func runSubprocess(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.codenotch.agy-cli-usage", qos: .utility)
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = currentDirectory
                process.standardInput = FileHandle.nullDevice

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: FetchError.launchFailed)
                    return
                }

                let pid = process.processIdentifier
                let stateLock = NSLock()
                var finished = false
                var didTimeout = false

                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    stateLock.lock()
                    let alreadyFinished = finished
                    if !alreadyFinished { didTimeout = true }
                    stateLock.unlock()
                    guard !alreadyFinished else { return }
                    Log.usage.debug("antigravity-cli: timed out after \(timeout, privacy: .public)s, terminating pid \(pid, privacy: .public)")
                    kill(pid, SIGTERM)
                    queue.asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
                timer.resume()

                // Drain stdout and stderr concurrently to avoid pipe buffer deadlocks.
                var stdoutData = Data()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdoutData = readBounded(from: stdoutPipe.fileHandleForReading, limit: maxOutputBytes)
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    _ = readBounded(from: stderrPipe.fileHandleForReading, limit: 64 * 1024)
                    readGroup.leave()
                }

                process.waitUntilExit()
                readGroup.wait()

                stateLock.lock()
                finished = true
                let timedOut = didTimeout
                stateLock.unlock()
                timer.cancel()

                if timedOut {
                    continuation.resume(throwing: FetchError.timedOut)
                    return
                }
                if process.terminationStatus != 0 {
                    continuation.resume(throwing: FetchError.nonZeroExit(process.terminationStatus))
                    return
                }
                continuation.resume(returning: stdoutData)
            }
        }
    }

    private static func readBounded(from handle: FileHandle, limit: Int) -> Data {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if buffer.count < limit {
                let remaining = limit - buffer.count
                buffer.append(chunk.prefix(remaining))
            }
        }
        return buffer
    }
}
