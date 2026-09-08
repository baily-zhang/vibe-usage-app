import Foundation

/// Shells out to `vibe-usage` CLI for config management.
/// The Mac app reads config.json directly (read-only) but all writes go through the CLI.
enum CLIBridge {
    typealias ExtraRoots = [String: [String]]

    enum CLIError: LocalizedError {
        case noRuntime
        case processFailure(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noRuntime: "未检测到 Node.js 或 Bun"
            case .processFailure(let msg): msg
            case .timeout: "CLI 操作超时"
            }
        }
    }

    // MARK: - Config Commands

    /// Set a config value: `vibe-usage config set <key> <value>`
    static func configSet(key: String, value: String) async throws {
        try await runCLI(args: ["config", "set", key, value])
    }

    /// Get a config value: `vibe-usage config get <key>`
    static func configGet(key: String) async throws -> String? {
        let output = try await runCLI(args: ["config", "get", key])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// List tool-specific additional roots as JSON.
    static func configRoots() async throws -> ExtraRoots {
        try decodeRoots(await runCLI(args: ["config", "roots"]))
    }

    static func configAddRoot(source: String, path: String) async throws {
        try await runCLI(args: ["config", "add-root", source, path])
    }

    static func configRemoveRoot(source: String, path: String) async throws {
        try await runCLI(args: ["config", "remove-root", source, path])
    }

    static func decodeRoots(_ output: String) throws -> ExtraRoots {
        guard let data = output.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode(ExtraRoots.self, from: data)
    }

    @discardableResult
    static func runCLI(
        args: [String],
        timeout: TimeInterval = 30,
        environmentOverrides: [String: String] = [:],
        environmentKeysToRemove: Set<String> = []
    ) async throws -> String {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // `Process.waitUntilExit()` is blocking. Keep it off the MainActor
                // so Settings remains responsive while npx/bun resolves the CLI.
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let runtime = RuntimeDetector.detect() else {
                        continuation.resume(throwing: CLIError.noRuntime)
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: runtime.executablePath)
                    process.arguments = RuntimeDetector.arguments(runtimeName: runtime.name, command: args)

                    // Inherit environment with runtime dir in PATH
                    var env = ProcessInfo.processInfo.environment
                    let runtimeDir = (runtime.executablePath as NSString).deletingLastPathComponent
                    if let existingPath = env["PATH"] {
                        env["PATH"] = "\(runtimeDir):\(existingPath)"
                    } else {
                        env["PATH"] = runtimeDir
                    }
                    env.merge(AppConfig.cliIdentityEnvironment) { _, appValue in appValue }
                    environmentKeysToRemove.forEach { env.removeValue(forKey: $0) }
                    env.merge(environmentOverrides) { _, overrideValue in overrideValue }

                    // In dev mode, tell CLI to use config.dev.json
                    #if DEBUG
                    env["VIBE_USAGE_DEV"] = "1"
                    #endif
                    process.environment = env

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    guard control.register(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    defer { control.unregister(process) }

                    var timeoutItem: DispatchWorkItem?
                    do {
                        try process.run()
                        control.stopIfRequested()
                        let item = DispatchWorkItem { control.timeout() }
                        timeoutItem = item
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                        process.waitUntilExit()
                        item.cancel()

                        if control.wasCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        if control.didTimeOut {
                            continuation.resume(throwing: CLIError.timeout)
                            return
                        }

                        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                        if process.terminationStatus == 0 {
                            continuation.resume(returning: stdout)
                        } else {
                            let msg = stderr.isEmpty ? "Exit code \(process.terminationStatus)" : stderr
                            continuation.resume(throwing: CLIError.processFailure(msg))
                        }
                    } catch {
                        timeoutItem?.cancel()
                        if control.wasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: CLIError.processFailure(error.localizedDescription))
                        }
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// Bridges structured-concurrency cancellation and the timeout deadline to
    /// Foundation `Process` without sharing mutable state unsafely.
    private final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancellationRequested = false
        private var timeoutRequested = false

        var wasCancelled: Bool {
            lock.withLock { cancellationRequested }
        }

        var didTimeOut: Bool {
            lock.withLock { timeoutRequested }
        }

        func register(_ process: Process) -> Bool {
            lock.withLock {
                guard !cancellationRequested else { return false }
                self.process = process
                return true
            }
        }

        func unregister(_ process: Process) {
            lock.withLock {
                if self.process === process { self.process = nil }
            }
        }

        func stopIfRequested() {
            let process = lock.withLock {
                cancellationRequested || timeoutRequested ? self.process : nil
            }
            if let process, process.isRunning { process.terminate() }
        }

        func cancel() {
            let process = lock.withLock { () -> Process? in
                cancellationRequested = true
                return self.process
            }
            if let process, process.isRunning { process.terminate() }
        }

        func timeout() {
            let process = lock.withLock { () -> Process? in
                guard !cancellationRequested,
                      let process = self.process,
                      process.isRunning
                else { return nil }
                timeoutRequested = true
                return process
            }
            if let process, process.isRunning { process.terminate() }
        }
    }
}
