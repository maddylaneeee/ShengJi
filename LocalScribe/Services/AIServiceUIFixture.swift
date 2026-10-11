#if DEBUG
import Foundation
import SwiftUI

/// Opt-in, isolated UI fixture. Entirely excluded from Release builds.
@MainActor
enum AIServiceUIFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["LOCALSCRIBE_AI_UI_FIXTURE"] == "1" }
    private static let preferences = AIServicePreferences(
        defaults: UserDefaults(suiteName: "ca.lixinchen.localscribe.ui-fixture." + UUID().uuidString)!,
        keys: FixtureKeys(), controlsRuntime: false)
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelListFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }()
    static var view: some View {
        VStack(spacing: 0) {
            Text("模拟数据 · 不代表账户实际可用模型")
                .font(.caption).foregroundStyle(.orange).padding(8)
            AIServiceConfigurationView(preferences: preferences,
                initialDraft: AIServiceConfiguration(provider: .openAI),
                temporaryKey: "ui-fixture-not-a-real-key", session: session)
        }
    }
}

private final class FixtureKeys: AIKeyStore {
    private var values: [AIServiceProvider: String] = [:]
    func read(_ provider: AIServiceProvider) throws -> String? { values[provider] }
    func write(_ key: String?, for provider: AIServiceProvider) throws { values[provider] = key }
}

private final class ModelListFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "api.openai.com", request.httpMethod == "GET", url.path == "/v1/models" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let body = Data(#"{"data":[{"id":"example-text-mini"},{"id":"example-text-standard"},{"id":"example-text-reasoning"}]}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
