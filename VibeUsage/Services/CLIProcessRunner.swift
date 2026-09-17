import Foundation

/// Runs the CLI off the UI/cooperative executor. Output goes to temporary files:
/// waiting for exit before draining a Pipe can deadlock as soon as it fills.
/// Files also let us finish when a descendant keeps an inherited output open.
enum CLIProcessRunner {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try execute(
                        executable: executable, arguments: arguments,
                        environment: environment, timeout: timeout
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class Deadline: @unchecked Sendable {
        // Accessed exclusively on queue, including the final synchronous read.
        let queue = DispatchQueue(label: "VibeUsage.CLIProcessDeadline")
        var expired = false
    }

    private static func execute(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> Output {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Deadline()
        let killItem = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            deadline.expired = true
            process.terminate()
            deadline.queue.asyncAfter(deadline: .now() + 1, execute: killItem)
        }
        deadline.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        process.waitUntilExit()
        let timedOut = deadline.queue.sync {
            timeoutItem.cancel()
            killItem.cancel()
            return deadline.expired
        }
        return Output(
            stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self),
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }
}
