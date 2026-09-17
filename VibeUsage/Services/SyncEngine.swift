import Foundation

/// Executes `npx @vibe-cafe/vibe-usage sync` (or bunx) and parses the result
actor SyncEngine {
    static let shared = SyncEngine()

    enum SyncResult {
        case success(String)
        case failure(SyncError)
    }

    enum SyncError: LocalizedError {
        case noRuntime
        case unauthorized
        case processFailure(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noRuntime:
                "未检测到 Node.js 或 Bun，请先安装"
            case .unauthorized:
                "API Key 无效，请重新配置"
            case .processFailure(let msg):
                "同步失败: \(msg)"
            case .timeout:
                "同步超时"
            }
        }
    }

    private var isRunning = false

    func runSync() async -> Result<String, SyncError> {
        guard !isRunning else {
            return .success("同步已在进行中")
        }
        isRunning = true
        defer { isRunning = false }

        guard let runtime = RuntimeDetector.detect() else {
            return .failure(.noRuntime)
        }

        var env = ProcessInfo.processInfo.environment
        let runtimeDir = (runtime.executablePath as NSString).deletingLastPathComponent
        env["PATH"] = runtimeDir + (env["PATH"].map { ":\($0)" } ?? "")
        env.merge(AppConfig.cliIdentityEnvironment) { _, appValue in appValue }
        #if DEBUG
        env["VIBE_USAGE_DEV"] = "1"
        #endif

        do {
            let output = try await CLIProcessRunner.run(
                executable: runtime.executablePath, arguments: runtime.syncArguments,
                environment: env, timeout: 120
            )
            return interpret(output)
        } catch {
            return .failure(.processFailure(error.localizedDescription))
        }
    }

    func interpret(_ output: CLIProcessRunner.Output) -> Result<String, SyncError> {
        if output.timedOut { return .failure(.timeout) }
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("[SyncEngine] Exit: \(output.exitCode)")
        debugLog("[SyncEngine] stdout: \(stdout.prefix(500))")
        debugLog("[SyncEngine] stderr: \(stderr.prefix(500))")
        if output.exitCode == 0 {
            return .success(stdout.isEmpty ? "同步完成" : stdout)
        }
        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if combined.contains("Invalid API key") || combined.contains("UNAUTHORIZED") {
            return .failure(.unauthorized)
        }
        return .failure(.processFailure(friendlyFailureMessage(combined, exitCode: output.exitCode)))
    }

    private func friendlyFailureMessage(_ message: String, exitCode: Int32) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Exit code \(exitCode)" }

        if trimmed.contains("RangeError: Invalid string length")
            || trimmed.contains("node:internal/readline") {
            return "本地同步工具读取历史记录时崩溃（RangeError: Invalid string length）。请更新 @vibe-cafe/vibe-usage 后重试；订阅配额监控可在设置中单独开启或关闭。"
        }

        return trimmed
    }
}
