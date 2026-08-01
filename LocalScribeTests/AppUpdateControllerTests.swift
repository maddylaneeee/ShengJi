import XCTest
@testable import LocalScribe

private actor UpdateClientProbe {
    private(set) var fetchCount = 0
    private(set) var prepareCount = 0

    func fetched() { fetchCount += 1 }
    func prepared() { prepareCount += 1 }
}

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testAutomaticUpdatesDefaultToEnabledAndPersistOptOut() {
        let defaults = makeDefaults()
        let controller = AppUpdateController(defaults: defaults)
        XCTAssertTrue(controller.automaticUpdatesEnabled)

        controller.setAutomaticUpdatesEnabled(false)
        XCTAssertFalse(controller.automaticUpdatesEnabled)

        let restored = AppUpdateController(defaults: defaults)
        XCTAssertFalse(restored.automaticUpdatesEnabled)
    }

    func testAutomaticCycleChecksAndPreparesNewerUpdate() async {
        let defaults = makeDefaults()
        let probe = UpdateClientProbe()
        let manifest = newerManifest
        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Prepared-ShengJi.app", isDirectory: true)
        let controller = AppUpdateController(
            defaults: defaults,
            currentVersion: "1.6.0",
            currentBuild: "23",
            manifestFetcher: { _ in
                await probe.fetched()
                return manifest
            },
            updatePreparer: { received, progress in
                XCTAssertEqual(received, manifest)
                await probe.prepared()
                progress(0.5)
                return preparedURL
            }
        )

        await controller.runAutomaticUpdateCycle()

        XCTAssertEqual(controller.state, .ready(manifest))
        XCTAssertEqual(controller.downloadedAppURL, preparedURL)
        let fetchCount = await probe.fetchCount
        let prepareCount = await probe.prepareCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(prepareCount, 1)
    }

    func testDisabledAutomaticCycleDoesNotUseNetwork() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppUpdateController.automaticUpdatesDefaultsKey)
        let probe = UpdateClientProbe()
        let manifest = newerManifest
        let controller = AppUpdateController(
            defaults: defaults,
            manifestFetcher: { _ in
                await probe.fetched()
                return manifest
            },
            updatePreparer: { _, _ in
                await probe.prepared()
                return URL(fileURLWithPath: "/tmp/unused.app")
            }
        )

        await controller.runAutomaticUpdateCycle()

        XCTAssertEqual(controller.state, .idle)
        let fetchCount = await probe.fetchCount
        let prepareCount = await probe.prepareCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(prepareCount, 0)
    }

    private var newerManifest: AppUpdateManifest {
        AppUpdateManifest(
            version: "9.0.0",
            build: "99",
            downloadURL: URL(string: "https://example.invalid/ShengJi.zip")!,
            sha256: String(repeating: "a", count: 64),
            releaseNotes: nil,
            minimumSystemVersion: "15.5",
            publishedAt: nil,
            sizeBytes: nil
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
