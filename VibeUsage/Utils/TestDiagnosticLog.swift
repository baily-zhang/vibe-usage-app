#if DEBUG || VIBE_USAGE_EXTERNAL_TEST
import Foundation

/// Local, exportable diagnostics for development/test builds only.
///
/// The entire implementation is excluded from ordinary Release binaries. It is
/// present only in Debug and explicitly flagged external-test builds. Entries
/// are deliberately typed: callers cannot attach raw stderr, response bodies,
/// paths, account identifiers, or credentials by accident.
enum TestDiagnosticLog {
    struct Entry: Codable, Sendable {
        var timestamp: String
        var event: String
        var providers: [String]
        var status: String?
        var meterCount: Int?
        var errorCode: String?
        var appVersion: String
        var osVersion: String
    }

    private static let queue = DispatchQueue(label: "ai.vibecafe.vibe-usage.test-diagnostics")
    private static let currentFilename = "diagnostics.jsonl"
    private static let previousFilename = "diagnostics.previous.jsonl"
    private static let maximumFileSize = 1_000_000

    static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppConfig.displayName, isDirectory: true)
    }

    static func recordQuotaRefreshStarted(
        _ providers: [ProviderRateLimit.Provider],
        directoryURL: URL? = nil,
        now: Date = Date()
    ) {
        record(
            event: "quota_refresh_started",
            providers: providers,
            directoryURL: directoryURL,
            now: now
        )
    }

    static func recordQuotaResult(
        _ snapshot: ProviderRateLimit,
        directoryURL: URL? = nil,
        now: Date = Date()
    ) {
        record(
            event: "quota_refresh_result",
            providers: [snapshot.provider],
            status: statusCode(snapshot.status),
            meterCount: snapshot.meters.count + [
                snapshot.fiveHour,
                snapshot.sevenDay,
                snapshot.sevenDayOpus,
                snapshot.sevenDaySonnet,
            ].compactMap { $0 }.count,
            directoryURL: directoryURL,
            now: now
        )
    }

    static func recordMissingQuotaResult(
        _ provider: ProviderRateLimit.Provider,
        directoryURL: URL? = nil,
        now: Date = Date()
    ) {
        record(
            event: "quota_refresh_result",
            providers: [provider],
            status: "missing_result",
            meterCount: 0,
            directoryURL: directoryURL,
            now: now
        )
    }

    static func recordQuotaFailure(
        _ providers: [ProviderRateLimit.Provider],
        error: Error,
        directoryURL: URL? = nil,
        now: Date = Date()
    ) {
        record(
            event: "quota_refresh_failed",
            providers: providers,
            errorCode: errorCode(error),
            directoryURL: directoryURL,
            now: now
        )
    }

    static func recordQuotaCancelled(
        _ providers: [ProviderRateLimit.Provider],
        directoryURL: URL? = nil,
        now: Date = Date()
    ) {
        record(
            event: "quota_refresh_cancelled",
            providers: providers,
            directoryURL: directoryURL,
            now: now
        )
    }

    static func export(to destinationURL: URL, directoryURL: URL? = nil) throws {
        let directory = directoryURL ?? defaultDirectoryURL
        record(
            event: "diagnostics_exported",
            providers: [],
            directoryURL: directory
        )
        let data = queue.sync { combinedData(in: directory) }
        try data.write(to: destinationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }

    private static func record(
        event: String,
        providers: [ProviderRateLimit.Provider],
        status: String? = nil,
        meterCount: Int? = nil,
        errorCode: String? = nil,
        directoryURL: URL? = nil,
        now: Date = Date()
    ) {
        // Unit tests must opt into an explicit temporary directory. Otherwise
        // their synthetic failures would pollute a developer's real test log.
        guard directoryURL != nil || !isRunningUnitTests else { return }
        let entry = Entry(
            timestamp: iso8601(now),
            event: event,
            providers: providers.map(\.rawValue),
            status: status,
            meterCount: meterCount,
            errorCode: errorCode,
            appVersion: AppConfig.version,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        let directory = directoryURL ?? defaultDirectoryURL
        queue.async { append(entry, to: directory) }
    }

    private static func append(_ entry: Entry, to directory: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )

            let current = directory.appendingPathComponent(currentFilename)
            rotateIfNeeded(current: current, directory: directory, fileManager: fileManager)
            if !fileManager.fileExists(atPath: current.path) {
                guard fileManager.createFile(
                    atPath: current.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else { return }
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: current.path
            )

            let encoder = JSONEncoder()
            var data = try encoder.encode(entry)
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Test diagnostics must never affect application behavior.
        }
    }

    private static func rotateIfNeeded(
        current: URL,
        directory: URL,
        fileManager: FileManager
    ) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: current.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maximumFileSize
        else { return }

        let previous = directory.appendingPathComponent(previousFilename)
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: current, to: previous)
    }

    private static func combinedData(in directory: URL) -> Data {
        let fileManager = FileManager.default
        var result = Data()
        for filename in [previousFilename, currentFilename] {
            let file = directory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: file.path),
               let data = try? Data(contentsOf: file) {
                result.append(data)
            }
        }
        return result
    }

    private static func statusCode(_ status: ProviderRateLimit.Status) -> String {
        switch status {
        case .ok: return "ok"
        case .noData: return "no_data"
        case .disabled: return "disabled"
        case .unauthorized: return "unauthorized"
        case .retryableError: return "retryable_error"
        case .error: return "error"
        }
    }

    private static func errorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let cliError = error as? CLIBridge.CLIError {
            switch cliError {
            case .noRuntime: return "cli_no_runtime"
            case .processFailure: return "cli_process_failure"
            case .timeout: return "cli_timeout"
            }
        }
        if let protocolError = error as? QuotaCLIBridge.ProtocolError {
            switch protocolError {
            case .unsupportedSchema: return "unsupported_schema"
            case .unknownProduct: return "unknown_product"
            }
        }
        if error is DecodingError { return "invalid_json" }
        if let rateLimitError = error as? any RateLimitFetchError {
            switch rateLimitError.rateLimitFailure {
            case .absent: return "provider_absent"
            case .notApplicable: return "not_applicable"
            case .unauthorized: return "unauthorized"
            case .transient: return "transient"
            }
        }
        return "unknown"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }
}
#endif
