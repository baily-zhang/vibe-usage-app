import Foundation

/// Detects available Node.js runtime (bun preferred, npx fallback)
enum RuntimeDetector {
    // Pin the cross-repository contract consumed by this app. A newer CLI can
    // change independently; advancing this version is an explicit app change
    // that is tested before release. Local development can still override it.
    // 0.10.32 is the quota release integrated with upstream 0.10.31. The
    // production packager verifies the published package's protocol first.
    static let defaultPackageSpecifier = "@vibe-cafe/vibe-usage@0.10.32"
    private static var bundledPackageSpecifier: String? {
        #if VIBE_USAGE_EXTERNAL_TEST
        Bundle.main.url(forResource: "vibe-usage-cli", withExtension: "tgz")?.path
        #else
        nil
        #endif
    }
    static var packageSpecifier: String {
        ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"]
            ?? bundledPackageSpecifier
            ?? defaultPackageSpecifier
    }
    private static var usesBundledPackage: Bool {
        ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"] == nil
            && bundledPackageSpecifier != nil
    }

    struct Runtime {
        let executablePath: String
        let name: String /// "bun" or "npx"

        /// Arguments to run vibe-usage sync
        var syncArguments: [String] {
            RuntimeDetector.arguments(runtimeName: name, command: ["sync"])
        }
    }

    static func arguments(runtimeName: String, command: [String]) -> [String] {
        arguments(
            runtimeName: runtimeName,
            command: command,
            packageSpecifier: packageSpecifier,
            usesBundledPackage: usesBundledPackage
        )
    }

    static func arguments(
        runtimeName: String,
        command: [String],
        packageSpecifier: String,
        usesBundledPackage: Bool
    ) -> [String] {
        if usesBundledPackage {
            return ["--yes", "--package", packageSpecifier, "vibe-usage"] + command
        }
        switch runtimeName {
        case "bun":
            return ["x", packageSpecifier] + command
        default:
            return ["--yes", packageSpecifier] + command
        }
    }

    /// Search common paths where node/bun might be installed
    private static let searchPaths: [String] = {
        // Start with PATH from environment
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        // Add common install locations that might not be in PATH
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/local/bin",
        ])

        // nvm: resolve actual version directory (nvm doesn't create a "current" symlink)
        paths.append(contentsOf: resolveNvmPaths(home: home))

        return paths
    }()

    /// Resolve nvm node bin paths by reading ~/.nvm/alias/default or scanning versions directory.
    private static func resolveNvmPaths(home: String) -> [String] {
        let nvmDir = "\(home)/.nvm"
        let versionsDir = "\(nvmDir)/versions/node"
        let fm = FileManager.default

        // 1. Try reading ~/.nvm/alias/default to find the default version
        let aliasPath = "\(nvmDir)/alias/default"
        if let alias = try? String(contentsOfFile: aliasPath, encoding: .utf8) {
            let prefix = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, let resolved = findNvmVersion(versionsDir: versionsDir, prefix: prefix, fm: fm) {
                return ["\(versionsDir)/\(resolved)/bin"]
            }
        }

        // 2. Fallback: pick the latest installed version (highest semver directory)
        if let entries = try? fm.contentsOfDirectory(atPath: versionsDir) {
            let sorted = entries
                .filter { $0.hasPrefix("v") }
                .sorted { compareVersions($0, $1) }
            if let latest = sorted.last {
                return ["\(versionsDir)/\(latest)/bin"]
            }
        }

        return []
    }

    /// Find the best matching nvm version directory for a given prefix (e.g. "22" matches "v22.22.0").
    private static func findNvmVersion(versionsDir: String, prefix: String, fm: FileManager) -> String? {
        // Normalize: "22" → "v22", "v22" → "v22", "lts/jod" → try lts alias
        var target = prefix
        if target.hasPrefix("lts/") {
            // Read lts alias: ~/.nvm/alias/lts/<name>
            let ltsName = String(target.dropFirst(4))
            let ltsAliasPath = "\(versionsDir)/../../alias/lts/\(ltsName)"
            if let ltsVersion = try? String(contentsOfFile: ltsAliasPath, encoding: .utf8) {
                target = ltsVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return nil
            }
        }

        let vPrefix = target.hasPrefix("v") ? target : "v\(target)"

        guard let entries = try? fm.contentsOfDirectory(atPath: versionsDir) else { return nil }
        // Find all versions matching prefix, pick highest
        let matches = entries
            .filter { $0.hasPrefix(vPrefix) && ($0 == vPrefix || $0.dropFirst(vPrefix.count).first == ".") }
            .sorted { compareVersions($0, $1) }
        return matches.last
    }

    /// Compare two version strings like "v22.11.0" and "v22.22.0" for sorting (ascending).
    private static func compareVersions(_ a: String, _ b: String) -> Bool {
        let partsA = a.dropFirst().split(separator: ".").compactMap { Int($0) }
        let partsB = b.dropFirst().split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va < vb }
        }
        return false
    }

    /// Detect the best available JS runtime
    static func detect() -> Runtime? {
        // External-test bundles carry an exact local CLI tarball. bun x does
        // not accept package-file paths, so this variant intentionally uses
        // npx and reports no runtime if Node/npm is missing.
        if usesBundledPackage {
            return findExecutable("npx").map { Runtime(executablePath: $0, name: "npx") }
        }
        // Local package paths are an integration-test hook; bun x does not
        // accept them, while npx does.
        if ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"] != nil,
           let npxPath = findExecutable("npx") {
            return Runtime(executablePath: npxPath, name: "npx")
        }
        // Prefer bun for speed
        if let bunPath = findExecutable("bun") {
            return Runtime(executablePath: bunPath, name: "bun")
        }
        if let npxPath = findExecutable("npx") {
            return Runtime(executablePath: npxPath, name: "npx")
        }
        return nil
    }

    private static func findExecutable(_ name: String) -> String? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
