import XCTest
@testable import LocalScribe

final class TranscriptionLifecycleTests: XCTestCase {
    private final class WorkerProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var didCancel = false
        private var didFinish = false

        var cancelled: Bool { lock.withLock { didCancel } }
        var finished: Bool { lock.withLock { didFinish } }

        func markCancelled() { lock.withLock { didCancel = true } }
        func markFinished() { lock.withLock { didFinish = true } }
    }

    func testTaskJoinSetWaitsForCancelledWorkerToFinish() async {
        let probe = WorkerProbe()
        let worker = Task {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
                        continuation.resume()
                    }
                }
            } onCancel: {
                probe.markCancelled()
            }
            probe.markFinished()
        }
        await Task.yield()

        let workers = TranscriptionTaskJoinSet([worker])
        workers.cancel()
        await workers.wait()

        XCTAssertTrue(probe.cancelled)
        XCTAssertTrue(probe.finished)
    }

    @MainActor
    func testSessionCancellationIsAwaitableAndIdempotent() async {
        let session = TranscriptionSessionModel(
            source: .recovered("Lifecycle test"),
            locale: Locale(identifier: "en"),
            configuration: RecognitionConfiguration(engine: .apple)
        )

        await session.cancel()
        await session.cancel()

        XCTAssertTrue(session.resourcesAreReleasedForTesting)
    }

    func testWhisperTemporaryPCMNamesAreUniqueUUIDs() {
        let first = WhisperFileProcessor.temporaryPCMURL()
        let second = WhisperFileProcessor.temporaryPCMURL()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.lastPathComponent.contains("(UUID().uuidString)"))
        XCTAssertTrue(first.lastPathComponent.hasPrefix("LocalScribe-Whisper-"))
        XCTAssertEqual(first.pathExtension, "f32")
    }

    func testCancelledSherpaConversionCreatesNoWAV() async {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let before = sherpaTemporaryWAVs(in: temporaryDirectory)
        let task = Task {
            try await SherpaAudioPreparer.makeMonoPCM16Wav(
                from: URL(fileURLWithPath: "/dev/null")
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A pre-cancelled conversion must not start.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(sherpaTemporaryWAVs(in: temporaryDirectory), before)
    }

    private func sherpaTemporaryWAVs(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter {
            $0.hasPrefix("LocalScribe-Sherpa-") && $0.hasSuffix(".wav")
        })
    }
}
