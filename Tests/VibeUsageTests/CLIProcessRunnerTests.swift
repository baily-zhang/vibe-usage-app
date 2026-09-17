import Foundation
import Testing
@testable import VibeUsage

struct CLIProcessRunnerTests {
    private func run(_ script: String, timeout: TimeInterval = 5) async throws -> CLIProcessRunner.Output {
        try await CLIProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"], timeout: timeout
        )
    }

    @Test
    func capturesOutputLargerThanBothPipeBuffersWithoutDeadlocking() async throws {
        let output = try await run("""
        head -c 262144 /dev/zero
        head -c 262144 /dev/zero >&2
        printf 'sync finished'
        """)
        #expect(output.exitCode == 0)
        #expect(!output.timedOut)
        #expect(output.stdout.utf8.count == 262144 + "sync finished".utf8.count)
        #expect(output.stderr.utf8.count == 262144)
    }

    @Test
    func normalBunResolutionOnStderrDoesNotFailSuccessfulSync() async throws {
        let output = try await run("""
        printf 'Resolving dependencies\nSaved lockfile\n' >&2
        printf '同步完成'
        """)
        let result = await SyncEngine().interpret(output)
        guard case .success(let message) = result else {
            Issue.record("Successful exit was treated as a sync failure")
            return
        }
        #expect(message == "同步完成")
    }

    @Test
    func timeoutIsReportedEvenWhenProcessIgnoresTermination() async throws {
        let start = Date()
        let output = try await run("trap '' TERM; printf 'Resolving dependencies' >&2; while :; do :; done", timeout: 0.1)
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(start) < 4)
        let result = await SyncEngine().interpret(output)
        guard case .failure(.timeout) = result else {
            Issue.record("Deadline was reported as Bun dependency failure")
            return
        }
    }

    @Test
    func descendantKeepingOutputOpenDoesNotDelayCompletion() async throws {
        let start = Date()
        let output = try await run("sleep 2 & printf done")
        #expect(output.exitCode == 0)
        #expect(output.stdout == "done")
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test
    func failureKeepsActualStdoutErrorAlongsideLauncherStderr() async throws {
        let output = try await run("printf 'actual sync error'; printf 'Saved lockfile' >&2; exit 1")
        let result = await SyncEngine().interpret(output)
        guard case .failure(.processFailure(let message)) = result else {
            Issue.record("Nonzero exit was not reported")
            return
        }
        #expect(message.contains("actual sync error"))
        #expect(message.contains("Saved lockfile"))
    }

    @Test
    func invalidExecutableFailsWithoutHanging() async {
        do {
            _ = try await CLIProcessRunner.run(
                executable: "/does-not-exist/vibe-usage", arguments: [],
                environment: [:], timeout: 0.1
            )
            Issue.record("Missing executable unexpectedly succeeded")
        } catch { }
    }
}
