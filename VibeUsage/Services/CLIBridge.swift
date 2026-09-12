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

    // MARK: - Private

    @discardableResult
    private static func runCLI(args: [String], timeout: TimeInterval = 30) async throws -> String {
        guard let runtime = RuntimeDetector.detect() else { throw CLIError.noRuntime }
        var env = ProcessInfo.processInfo.environment
        let runtimeDir = (runtime.executablePath as NSString).deletingLastPathComponent
        env["PATH"] = runtimeDir + (env["PATH"].map { ":\($0)" } ?? "")
        env.merge(AppConfig.cliIdentityEnvironment) { _, appValue in appValue }
        #if DEBUG
        env["VIBE_USAGE_DEV"] = "1"
        #endif
        let output = try await CLIProcessRunner.run(
            executable: runtime.executablePath,
            arguments: RuntimeDetector.arguments(runtimeName: runtime.name, command: args),
            environment: env, timeout: timeout
        )
        if output.timedOut { throw CLIError.timeout }
        guard output.exitCode == 0 else {
            let message = [output.stdout, output.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            throw CLIError.processFailure(message.isEmpty ? "Exit code \(output.exitCode)" : message)
        }
        return output.stdout
    }
}
