import Foundation
import Darwin
import XCTest
@testable import LocalScribe

final class AIServiceTests: XCTestCase {
    func testProviderRequestsUseSeparateParametersAndOfficialEndpoints() throws {
        for provider in AIServiceProvider.allCases {
            let config = AIServiceConfiguration(provider: provider, modelID: "fixture-text-model", cloudConsent: true)
            let client = OpenAICompatibleClient(configuration: config, key: "fixture-not-real")
            let request = try client.generationRequest(system: "system", data: "中文", maxTokens: 512)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(request.url?.absoluteString, provider.defaultURL + "/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-not-real")
            XCTAssertEqual(body["model"] as? String, "fixture-text-model")
            XCTAssertNil(body["chat_template_kwargs"])
            XCTAssertNil(body["seed"])
            if provider == .openAI {
                XCTAssertEqual(body["max_completion_tokens"] as? Int, 512)
                XCTAssertNil(body["temperature"])
                XCTAssertNil(body["max_tokens"])
                XCTAssertEqual(body["store"] as? Bool, false)
            } else {
                XCTAssertEqual(body["max_tokens"] as? Int, 512)
                XCTAssertNil(body["max_completion_tokens"])
            }
            if provider == .deepSeek {
                XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            }
        }
    }

    func testLocalURLNormalizationAndAddressBoundary() throws {
        for address in ["http://localhost:1234", "http://127.0.0.1:4321/v1/", "http://[::1]:1234/"] {
            let config = AIServiceConfiguration(localURL: address)
            XCTAssertEqual(try config.baseURL().path, "/v1")
        }
        for address in ["http://192.168.0.4:1234/v1", "https://example.com/v1", "http://127.0.0.1.evil/v1",
                        "http://user:pass@localhost:1234", "http://localhost:1234?key=secret",
                        "http://localhost:1234/#fragment", "file:///v1", "http://localhost:0/v1",
                        "http://localhost:1234/v1/v1"] {
            XCTAssertThrowsError(try AIServiceConfiguration(localURL: address).baseURL(), address)
        }
        var cloud = AIServiceConfiguration(provider: .openAI)
        cloud.localURL = "https://example.com"
        XCTAssertEqual(try cloud.baseURL().host, "api.openai.com")
    }

    func testMissingCredentialsOrConsentNeverConstructsGenerationRequest() throws {
        for provider in [AIServiceProvider.openAI, .deepSeek] {
            let config = AIServiceConfiguration(provider: provider, modelID: "fixture", cloudConsent: true)
            XCTAssertThrowsError(try OpenAICompatibleClient(configuration: config, key: nil)
                .generationRequest(system: "s", data: "d", maxTokens: 10)) { XCTAssertEqual($0 as? AIServiceError, .missingKey) }
            var unconfirmed = config
            unconfirmed.cloudConsent = false
            XCTAssertThrowsError(try OpenAICompatibleClient(configuration: unconfirmed, key: "fixture")
                .generationRequest(system: "s", data: "d", maxTokens: 10)) { XCTAssertEqual($0 as? AIServiceError, .consentRequired) }
        }
        let local = AIServiceConfiguration(modelID: "fixture")
        XCTAssertNil(try OpenAICompatibleClient(configuration: local, key: nil)
            .generationRequest(system: "s", data: "d", maxTokens: 10).value(forHTTPHeaderField: "Authorization"))
    }

    func testModelListExplainsMissingCloudKeyButAllowsLocalServerWithoutToken() {
        for provider in [AIServiceProvider.openAI, .deepSeek] {
            let config = AIServiceConfiguration(provider: provider)
            XCTAssertEqual(config.modelListBlocker(key: nil), AIServiceError.missingKey.localizedDescription)
            XCTAssertNil(config.modelListBlocker(key: "fixture")) // No model ID or upload consent needed for GET.
        }
        XCTAssertNil(AIServiceConfiguration().modelListBlocker(key: nil))
        XCTAssertNotNil(AIServiceConfiguration(localURL: "http://example.com/v1").modelListBlocker(key: nil))
    }

    func testSSEParserIgnoresReasoningAndUsageButRequiresCompleteStop() throws {
        var parser = AIChatResponseParser()
        try parser.consume(#"{"choices":[{"index":0,"delta":{"reasoning_content":"hidden","content":"中文"},"finish_reason":null}]}"#)
        try parser.consume(#"{"choices":[],"usage":{"total_tokens":5}}"#)
        XCTAssertThrowsError(try parser.result())
        try parser.consume(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        XCTAssertThrowsError(try parser.result())
        try parser.consume("[DONE]")
        XCTAssertEqual(try parser.result(), "中文")
    }

    func testSSERejectsTruncationRefusalToolsErrorsAndMultipleChoices() {
        let invalid = [
            #"{"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"insufficient_system_resource"}]}"#,
            #"{"choices":[{"delta":{"refusal":"no"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{}]},"finish_reason":null}]}"#,
            #"{"error":{"message":"must never be shown"}}"#,
            #"{"choices":[{"delta":{}},{"delta":{}}]}"#,
            #"{"choices":[{"index":1,"delta":{"content":"other"}}]}"#,
            "invalid JSON"
        ]
        for event in invalid {
            var parser = AIChatResponseParser()
            XCTAssertThrowsError(try parser.consume(event))
        }
        var empty = AIChatResponseParser()
        XCTAssertNoThrow(try empty.consume("[DONE]"))
        XCTAssertThrowsError(try empty.result())
    }

    func testJSONResponseRequiresSingleFinalText() throws {
        let valid = #"{"choices":[{"message":{"content":"中文","reasoning_content":"hidden"},"finish_reason":"stop"}]}"#
        XCTAssertEqual(try AIChatResponseParser.json(Data(valid.utf8)), "中文")
        for json in [valid.replacingOccurrences(of: "stop", with: "length"),
                     #"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#,
                     #"{"choices":[{"message":{"content":"OK","tool_calls":[{}]},"finish_reason":"stop"}]}"#] {
            XCTAssertThrowsError(try AIChatResponseParser.json(Data(json.utf8)))
        }
    }

    func testRealLoopbackSSEHandlesUTF8ByteFragmentsAndHeartbeats() async throws {
        let body = ": heartbeat\n\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好🌏\"},\"finish_reason\":null}]}\n\n" +
            "data: {\"choices\":[],\"usage\":{\"total_tokens\":8}}\n\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
            "data: [DONE]\n\n"
        let server = try LoopbackAIHTTPFixture(body: body, contentType: "text/event-stream", fragmentSize: 1)
        defer { server.stop() }
        let config = AIServiceConfiguration(localURL: server.baseURL, modelID: "fixture")
        let value = try await OpenAICompatibleClient(configuration: config, key: nil)
            .complete(system: "s", data: "synthetic", maxTokens: 32)
        XCTAssertEqual(value, "你好🌏")
    }

    func testRealLoopbackAbruptSSEEndDoesNotApplyPartialOutput() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
        let server = try LoopbackAIHTTPFixture(body: body, contentType: "text/event-stream")
        defer { server.stop() }
        let client = OpenAICompatibleClient(configuration: AIServiceConfiguration(localURL: server.baseURL, modelID: "fixture"), key: nil)
        do { _ = try await client.complete(system: "s", data: "d", maxTokens: 32); XCTFail("Incomplete stream succeeded") }
        catch { XCTAssertEqual(error as? AIServiceError, .invalidOutput) }
    }

    func testRealLoopbackJSONAndModelDiscovery() async throws {
        let server = try LoopbackAIHTTPFixture(body: #"{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#, contentType: "application/json")
        defer { server.stop() }
        let config = AIServiceConfiguration(localURL: server.baseURL, modelID: "fixture", stream: false)
        let result = try await OpenAICompatibleClient(configuration: config, key: nil).complete(system: "s", data: "d", maxTokens: 32)
        XCTAssertEqual(result, "OK")
        let models = try LoopbackAIHTTPFixture(body: #"{"data":[{"id":"text-b"},{"id":"text-a"},{"id":"text-a"},{"id":"image","output_modalities":["image"]}]}"#, contentType: "application/json")
        defer { models.stop() }
        let list = try await OpenAICompatibleClient(configuration: AIServiceConfiguration(localURL: models.baseURL), key: nil).models()
        XCTAssertEqual(list, ["text-a", "text-b"])
    }

    func testOfficialCloudFixturesNeverContactNetworkAndKeepKeyIsolation() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AICloudFixtureProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        for provider in [AIServiceProvider.openAI, .deepSeek] {
            let config = AIServiceConfiguration(provider: provider, modelID: "fixture", stream: false, cloudConsent: true)
            let client = OpenAICompatibleClient(configuration: config, key: "fixture-" + provider.rawValue, session: session)
            let models = try await client.models()
            XCTAssertEqual(models, ["fixture"])
            let text = try await client.complete(system: "s", data: "synthetic", maxTokens: 32)
            XCTAssertEqual(text, "OK")
        }
    }

    func testHTTPFailuresAreRedactedAndNeverAutomaticallyRetried() async throws {
        for (status, expected) in [(401, AIServiceError.authentication), (429, .rateLimited), (404, .modelUnavailable), (500, .http(500))] {
            let server = try LoopbackAIHTTPFixture(body: "private-key-and-transcript", contentType: "application/json", status: status)
            defer { server.stop() }
            let client = OpenAICompatibleClient(configuration: AIServiceConfiguration(localURL: server.baseURL, modelID: "fixture"), key: "fixture-secret")
            do { _ = try await client.complete(system: "s", data: "d", maxTokens: 32); XCTFail("HTTP failure succeeded") }
            catch { XCTAssertEqual(error as? AIServiceError, expected); XCTAssertFalse(error.localizedDescription.contains("private-key")) }
            XCTAssertEqual(server.requestCount, 1)
        }
    }

    func testRedirectIsNotFollowed() async throws {
        let destination = try LoopbackAIHTTPFixture(body: "should never be reached", contentType: "application/json")
        defer { destination.stop() }
        let redirect = try LoopbackAIHTTPFixture(body: "", contentType: "application/json", status: 302,
            extraHeader: "Location: \(destination.baseURL)/chat/completions\r\n")
        defer { redirect.stop() }
        let client = OpenAICompatibleClient(configuration: AIServiceConfiguration(localURL: redirect.baseURL, modelID: "fixture"), key: "fixture")
        do { _ = try await client.complete(system: "s", data: "d", maxTokens: 10); XCTFail("Redirect succeeded") }
        catch { XCTAssertEqual(error as? AIServiceError, .redirect) }
        XCTAssertEqual(destination.requestCount, 0)
    }

    func testTotalTimeoutAndCancellationInterruptSlowSSE() async throws {
        let server = try LoopbackAIHTTPFixture(body: ": heartbeat\n\n", contentType: "text/event-stream", stall: true)
        defer { server.stop() }
        let config = AIServiceConfiguration(localURL: server.baseURL, modelID: "fixture")
        let client = OpenAICompatibleClient(configuration: config, key: nil, totalTimeout: .milliseconds(100))
        do { _ = try await client.complete(system: "s", data: "d", maxTokens: 10); XCTFail("Timeout succeeded") }
        catch { XCTAssertEqual(error as? AIServiceError, .timedOut) }
        let task = Task { try await OpenAICompatibleClient(configuration: config, key: nil).complete(system: "s", data: "d", maxTokens: 10) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testPreferencesPersistMissingKeyAndIsolateCredentialsFromDefaults() throws {
        let name = "AIServiceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keys = MemoryAIKeys()
        let prefs = AIServicePreferences(defaults: defaults, keys: keys, controlsRuntime: false)
        XCTAssertFalse(prefs.isEnabled)
        let oldRevision = prefs.revision
        prefs.setEnabled(true)
        XCTAssertNotEqual(prefs.revision, oldRevision)
        XCTAssertNotNil(prefs.readinessError)
        let cloud = AIServiceConfiguration(provider: .openAI, modelID: "fixture", cloudConsent: true)
        try prefs.save(cloud)
        XCTAssertEqual(prefs.readinessError, AIServiceError.missingKey.localizedDescription)
        try prefs.save(cloud, replacementKey: "secret-openai-fixture")
        XCTAssertNil(prefs.readinessError)
        XCTAssertNil(try prefs.key(for: .deepSeek))
        let encoded = try XCTUnwrap(defaults.data(forKey: AIServicePreferences.configurationsKey))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret-openai-fixture"))
        let reload = AIServicePreferences(defaults: defaults, keys: keys, controlsRuntime: false)
        XCTAssertTrue(reload.isEnabled)
        XCTAssertEqual(reload.configuration, cloud)
        try reload.save(cloud) // Blank input keeps the saved key.
        XCTAssertEqual(try reload.key(for: .openAI), "secret-openai-fixture")
        try reload.save(cloud, replacementKey: "")
        XCTAssertNil(try reload.key(for: .openAI))
    }

    @MainActor
    func testKeychainFailureDoesNotPartiallySaveConfiguration() throws {
        let name = "AIServiceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keys = MemoryAIKeys()
        keys.failWrites = true
        let prefs = AIServicePreferences(defaults: defaults, keys: keys, controlsRuntime: false)
        XCTAssertThrowsError(try prefs.save(AIServiceConfiguration(provider: .deepSeek, modelID: "fixture"), replacementKey: "fixture"))
        XCTAssertEqual(prefs.provider, .lmStudio)
        XCTAssertNil(defaults.data(forKey: AIServicePreferences.configurationsKey))
    }

    func testDeviceOnlyKeychainRoundTripWithDisposableFixture() throws {
        let keys = AIKeychainStore(service: "ca.lixinchen.localscribe.tests." + UUID().uuidString)
        defer { try? keys.write(nil, for: .openAI) }
        XCTAssertNil(try keys.read(.openAI))
        try keys.write("disposable-fixture-not-real", for: .openAI)
        XCTAssertEqual(try keys.read(.openAI), "disposable-fixture-not-real")
        XCTAssertNil(try keys.read(.deepSeek))
        try keys.write("replacement-fixture", for: .openAI)
        XCTAssertEqual(try keys.read(.openAI), "replacement-fixture")
        try keys.write(nil, for: .openAI)
        XCTAssertNil(try keys.read(.openAI))
    }

    @MainActor
    func testCustomModeRejectsDownloadInstallAndPreparationWithoutNetwork() async throws {
        let oldMode = UserDefaults.standard.object(forKey: AIServiceMode.defaultsKey)
        defer { UserDefaults.standard.set(oldMode, forKey: AIServiceMode.defaultsKey) }
        AIServiceMode.setEnabled(true)
        let spy = AIInvocationCounter()
        let manager = GemmaModelManager(installer: { _, _ in await spy.increment() })
        manager.download(.e2b)
        if case .failed(_, let message) = manager.state { XCTAssertEqual(message, AIServiceError.customMode.localizedDescription) }
        else { XCTFail("Download was not blocked") }
        let calls = await spy.count
        XCTAssertEqual(calls, 0)
        do { try await GemmaModelStore.install(.e2b, progress: { _ in }); XCTFail("Install allowed") }
        catch { XCTAssertEqual(error as? AIServiceError, .customMode) }
        do { try await AIOptimizationService().prepare(model: .e2b); XCTFail("Preparation allowed") }
        catch { XCTAssertEqual(error as? AIServiceError, .customMode) }
        do { try AIServiceMode.withBuiltInAllowed { XCTFail("Commit/process boundary allowed") } }
        catch { XCTAssertEqual(error as? AIServiceError, .customMode) }
    }

    @MainActor
    func testEnablingCustomModeCancelsSharedInFlightDownload() async throws {
        let oldMode = UserDefaults.standard.object(forKey: AIServiceMode.defaultsKey)
        let oldGemma = UserDefaults.standard.object(forKey: "EnableGemma")
        defer {
            UserDefaults.standard.set(oldMode, forKey: AIServiceMode.defaultsKey)
            UserDefaults.standard.set(oldGemma, forKey: "EnableGemma")
        }
        AIServiceMode.setEnabled(false)
        UserDefaults.standard.set(true, forKey: "EnableGemma")
        let started = expectation(description: "download started")
        let cancelled = expectation(description: "download cancelled")
        let manager = GemmaModelManager(installer: { _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled.fulfill(); throw error }
        })
        manager.download(.e2b)
        await fulfillment(of: [started], timeout: 2)
        let prefs = AIServicePreferences(keys: MemoryAIKeys(), downloads: manager)
        prefs.setEnabled(true)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(manager.state, .idle)
        manager.download(.e2b)
        XCTAssertFalse(manager.state.isDownloading)
    }

    func testAlreadyCancelledDownloadCannotStartOrHang() async throws {
        let operation = ModelDownloadOperation(source: URL(string: "http://127.0.0.1:1/no-network")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), progress: { _ in })
        operation.cancel()
        do { try await operation.start(); XCTFail("Cancelled operation started") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCustomProofreadingKeepsSafetyRulesWithoutPreparingGemma() async throws {
        let source = TranscriptSegment(startTime: 0, endTime: 2, text: "Um, review 42 items at 09:15.")
        let response = "[{\"id\":\"\(source.id.uuidString)\",\"text\":\"Review 42 items at 09:15.\"}]"
        let client = ScriptedAIClient(responses: [response])
        let result = try await AIOptimizationService().optimize(segments: [source], fallbackText: source.text,
            kind: .proofread, prompt: "", model: .e2b, client: client, progress: { _, _ in })
        XCTAssertEqual(result.segments.first?.id, source.id)
        XCTAssertEqual(result.text, "Review 42 items at 09:15.")
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(GemmaProcessRegistry.activeProcessCount, 0)
    }

    func testInvalidCustomProofreadingRetriesOnlyOnceThenPreservesOriginal() async throws {
        let source = TranscriptSegment(startTime: 0, endTime: 2, text: "Review 42 items.")
        let client = ScriptedAIClient(responses: ["not JSON", "still not JSON"])
        let result = try await AIOptimizationService().optimize(segments: [source], fallbackText: source.text,
            kind: .proofread, prompt: "", model: .e2b, client: client, progress: { _, _ in })
        XCTAssertEqual(result.text, source.text)
        XCTAssertEqual(result.failures.count, 1)
        let count = await client.calls
        XCTAssertEqual(count, 2)
    }

    func testCustomProofreadingRejectsChangedNumbers() async throws {
        let source = TranscriptSegment(startTime: 0, endTime: 2, text: "Review 42 items.")
        let client = ScriptedAIClient(responses: ["[{\"id\":\"\(source.id.uuidString)\",\"text\":\"Review 43 items.\"}]"])
        let result = try await AIOptimizationService().optimize(segments: [source], fallbackText: source.text,
            kind: .proofread, prompt: "", model: .e2b, client: client, progress: { _, _ in })
        XCTAssertEqual(result.text, source.text)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testCustomSummaryUsesSameValidationPipeline() async throws {
        let source = TranscriptSegment(startTime: 0, endTime: 2,
            text: "The team reviewed 42 items for the project. The team will send the report on Tuesday. The report will contain the final review results and next steps.")
        let client = ScriptedAIClient(responses: ["The team reviewed 42 items and will send the report on Tuesday."])
        let result = try await AIOptimizationService().optimize(segments: [source], fallbackText: source.text,
            kind: .summarize, prompt: "", model: .e2b, client: client, progress: { _, _ in })
        XCTAssertEqual(result.summary, "The team reviewed 42 items and will send the report on Tuesday.")
    }

    func testConcurrentWindowsCannotCrossCancelAndRevisionCancelsOldJob() async throws {
        let source = TranscriptSegment(startTime: 0, endTime: 2, text: "Synthetic text.")
        let service = AIOptimizationService()
        let firstOwner = UUID(), secondOwner = UUID(), revision = UUID()
        let started = expectation(description: "client started")
        let client = SlowAIClient(started: { started.fulfill() })
        let task = Task { try await service.optimize(segments: [source], fallbackText: source.text,
            kind: .proofread, prompt: "", model: .e2b, client: client, ownerID: firstOwner,
            configurationRevision: revision, progress: { _, _ in }) }
        await fulfillment(of: [started], timeout: 2)
        await service.cancel(ownerID: secondOwner)
        do {
            _ = try await service.optimize(segments: [source], fallbackText: source.text,
                kind: .proofread, prompt: "", model: .e2b, client: client, ownerID: secondOwner, progress: { _, _ in })
            XCTFail("Concurrent job was allowed")
        } catch { XCTAssertEqual(error as? AIServiceError, .busy) }
        await service.cancelConfiguration(revision: revision)
        do { _ = try await task.value; XCTFail("Old job completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class MemoryAIKeys: AIKeyStore {
    var values: [AIServiceProvider: String] = [:]
    var failWrites = false
    func read(_ provider: AIServiceProvider) throws -> String? { values[provider] }
    func write(_ key: String?, for provider: AIServiceProvider) throws {
        if failWrites { throw AIServiceError.keychain(-1) }
        values[provider] = key.flatMap { $0.isEmpty ? nil : $0 }
    }
}
private actor AIInvocationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
private actor ScriptedAIClient: AITextGenerationClient {
    private var responses: [String]
    private(set) var calls = 0
    init(responses: [String]) { self.responses = responses }
    func complete(system: String, data: String, maxTokens: Int, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        calls += 1
        guard !responses.isEmpty else { throw AIServiceError.invalidOutput }
        let value = responses.removeFirst()
        partial(value)
        return value
    }
}
private struct SlowAIClient: AITextGenerationClient {
    let started: @Sendable () -> Void
    func complete(system: String, data: String, maxTokens: Int, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        started()
        try await Task.sleep(for: .seconds(10))
        return "should have been cancelled"
    }
}

/// A real loopback socket with deliberately fragmented UTF-8; never leaves the Mac.
private final class LoopbackAIHTTPFixture: @unchecked Sendable {
    private let socketFD: Int32
    private let lock = NSLock()
    private var connections: Set<Int32> = []
    private var stopped = false
    private var count = 0
    let baseURL: String
    var requestCount: Int { lock.withLock { count } }
    init(body: String, contentType: String, fragmentSize: Int = 64, status: Int = 200,
         extraHeader: String = "", stall: Bool = false) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AIServiceError.unreachable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 8) == 0 else { close(fd); throw AIServiceError.unreachable }
        socketFD = fd
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/v1"
        let data = Data(body.utf8)
        let sizeHeader = stall ? "" : "Content-Length: \(data.count)\r\n"
        let headers = Data("HTTP/1.1 \(status) Fixture\r\nContent-Type: \(contentType)\r\n\(sizeHeader)\(extraHeader)Connection: close\r\n\r\n".utf8)
        DispatchQueue.global().async { [weak self] in
            while let self, !self.lock.withLock({ self.stopped }) {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { break }
                self.lock.withLock { _ = self.connections.insert(connection) }
                var noSignal: Int32 = 1
                _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global().async { [weak self] in
                    guard let self else { close(connection); return }
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    guard recv(connection, &buffer, buffer.count, 0) > 0 else { self.closeConnection(connection); return }
                    self.lock.withLock { self.count += 1 }
                    guard self.send(headers, to: connection) else { self.closeConnection(connection); return }
                    for offset in stride(from: 0, to: data.count, by: fragmentSize) {
                        guard self.send(Data(data[offset..<min(offset + fragmentSize, data.count)]), to: connection) else { break }
                        usleep(2_000)
                    }
                    if !stall { self.closeConnection(connection) }
                }
            }
        }
    }
    private func send(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let size = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                guard size > 0 else { return false }
                offset += size
            }
            return true
        }
    }
    private func closeConnection(_ fd: Int32) {
        lock.withLock {
            if connections.remove(fd) != nil { shutdown(fd, SHUT_RDWR); close(fd) }
        }
    }
    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            shutdown(socketFD, SHUT_RDWR); close(socketFD)
            for fd in connections { shutdown(fd, SHUT_RDWR); close(fd) }
            connections.removeAll()
        }
    }
}

private final class AICloudFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let provider: AIServiceProvider = request.url?.host == "api.openai.com" ? .openAI : .deepSeek
        XCTAssertTrue(["api.openai.com", "api.deepseek.com"].contains(request.url?.host ?? ""))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-" + provider.rawValue)
        let body = request.url?.path.hasSuffix("/models") == true
            ? #"{"data":[{"id":"fixture"}]}"# : #"{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
