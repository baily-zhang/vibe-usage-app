import Foundation
import Testing
@testable import VibeUsage

struct QuotaCLIBridgeTests {
    private let payload = """
    {
      "schemaVersion": 1,
      "products": [{
        "id": "kimi-code",
        "status": "ok",
        "meters": [{
          "id": "weekly",
          "label": "7d",
          "utilization": 42.5,
          "resetsAt": "2026-09-14T00:00:00.000Z",
          "windowSeconds": 604800
        }],
        "planLabel": "Pro",
        "fetchedAt": "2026-09-07T00:00:00.000Z",
        "dataAsOf": "2026-09-07T00:00:00.000Z",
        "source": "live"
      }]
    }
    """

    @Test
    func decodesVersionedMetersIntoProviderNeutralSnapshots() throws {
        let envelope = try QuotaCLIBridge.decode(payload)
        let snapshots = try QuotaCLIBridge.snapshots(from: envelope)
        let snapshot = try #require(snapshots.first)
        let meter = try #require(snapshot.meters.first)

        #expect(snapshot.provider == .kimiCode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "Pro")
        #expect(meter.id == "weekly")
        #expect(meter.label == "7d")
        #expect(meter.window.utilization == 42.5)
        #expect(meter.window.windowDuration == 604_800)
        #expect(meter.window.resetsAt == Date(timeIntervalSince1970: 1_789_344_000))
    }

    @Test
    func rejectsAnUnknownSchemaBeforeUsingAnyProductData() throws {
        let envelope = QuotaCLIBridge.Envelope(schemaVersion: 2, products: [])
        #expect(throws: QuotaCLIBridge.ProtocolError.self) {
            _ = try QuotaCLIBridge.snapshots(from: envelope)
        }
    }

    @Test
    func mapsCredentialAndTransientFailuresPerProvider() throws {
        let credential = QuotaCLIBridge.Product(
            id: "zcode",
            status: "missing_credentials",
            meters: [],
            fetchedAt: Date(),
            source: "live"
        )
        let transient = QuotaCLIBridge.Product(
            id: "kimi-code",
            status: "retryable_error",
            meters: [],
            fetchedAt: Date(),
            source: "live"
        )
        let snapshots = try QuotaCLIBridge.snapshots(from: .init(
            schemaVersion: 1,
            products: [credential, transient]
        ))

        #expect(snapshots.first(where: { $0.provider == .zCode })?.status == .unauthorized)
        #expect(snapshots.first(where: { $0.provider == .kimiCode })?.status == .retryableError)
    }

    @Test
    func exposesZCodeKeyOnlyWhenZCodeIsExplicitlyRequested() {
        let kimiOnly = QuotaCLIBridge.quotaEnvironment(
            providers: [.kimiCode],
            zCodeAPIKey: "secret-fixture"
        )
        #expect(kimiOnly.overrides.isEmpty)
        #expect(kimiOnly.keysToRemove == ["BIGMODEL_API_KEY", "Z_AI_API_KEY"])

        let zAI = QuotaCLIBridge.quotaEnvironment(
            providers: [.zCode],
            zCodeAPIKey: "  secret-fixture  ",
            zCodeRegion: .zAI
        )
        #expect(zAI.overrides == ["Z_AI_API_KEY": "secret-fixture"])
        #expect(zAI.keysToRemove == ["BIGMODEL_API_KEY"])

        let bigModel = QuotaCLIBridge.quotaEnvironment(
            providers: [.zCode],
            zCodeAPIKey: "bigmodel-secret",
            zCodeRegion: .bigModel
        )
        #expect(bigModel.overrides == ["BIGMODEL_API_KEY": "bigmodel-secret"])
        #expect(bigModel.keysToRemove == ["Z_AI_API_KEY"])
    }
}
