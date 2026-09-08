import XCTest
@testable import VibeUsage

final class RuntimeDetectorTests: XCTestCase {
    func testExternalBundleUsesNpxPackageSyntaxForLocalTarball() {
        XCTAssertEqual(
            RuntimeDetector.arguments(
                runtimeName: "npx",
                command: ["quota", "discover", "--json"],
                packageSpecifier: "/Applications/Vibe Usage Test.app/Contents/Resources/vibe-usage-cli.tgz",
                usesBundledPackage: true
            ),
            [
                "--yes",
                "--package",
                "/Applications/Vibe Usage Test.app/Contents/Resources/vibe-usage-cli.tgz",
                "vibe-usage",
                "quota",
                "discover",
                "--json",
            ]
        )
    }

    func testBunUsesPinnedCompatiblePackage() {
        XCTAssertEqual(RuntimeDetector.defaultPackageSpecifier, "@vibe-cafe/vibe-usage@0.10.23")
        XCTAssertEqual(
            RuntimeDetector.arguments(runtimeName: "bun", command: ["sync"]),
            ["x", RuntimeDetector.packageSpecifier, "sync"]
        )
    }

    func testNpxUsesPinnedPackageForConfigCommands() {
        XCTAssertEqual(
            RuntimeDetector.arguments(runtimeName: "npx", command: ["config", "get", "apiKey"]),
            ["--yes", RuntimeDetector.packageSpecifier, "config", "get", "apiKey"]
        )
    }

    func testMacAppIdentityUsesTheDisplayVersion() {
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE"], "mac-app")
        XCTAssertEqual(AppConfig.cliIdentityEnvironment["VIBE_USAGE_SURFACE_VERSION"], AppConfig.version)
    }
}
