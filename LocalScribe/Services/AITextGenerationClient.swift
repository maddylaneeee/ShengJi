import Foundation

protocol AITextGenerationClient: Sendable {
    func complete(system: String, data: String, maxTokens: Int,
                  partial: @escaping @Sendable (String) -> Void) async throws -> String
}

extension AITextGenerationClient {
    func complete(system: String, data: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, data: data, maxTokens: maxTokens, partial: { _ in })
    }
}

struct BuiltInGemmaClient: AITextGenerationClient {
    func complete(system: String, data: String, maxTokens: Int,
                  partial: @escaping @Sendable (String) -> Void) async throws -> String {
        guard !AIServiceMode.usesCustomService else { throw CancellationError() }
        return try await GemmaRuntime.shared.complete(system: system, data: data, maxTokens: maxTokens, partial: partial)
    }
}

private final class AIRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Do not forward keys or transcript data, including same-host redirects.
        completionHandler(nil)
    }
}

struct OpenAICompatibleClient: AITextGenerationClient, @unchecked Sendable {
    let configuration: AIServiceConfiguration
    private let key: String?
    private let session: URLSession
    private let totalTimeout: Duration
    init(configuration: AIServiceConfiguration, key: String?, session: URLSession? = nil,
         totalTimeout: Duration = .seconds(180)) {
        self.configuration = configuration
        self.key = key
        self.totalTimeout = totalTimeout
        self.session = session ?? Self.productionSession
    }

    static let productionSession: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 180
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        return URLSession(configuration: settings, delegate: AIRequestDelegate(), delegateQueue: nil)
    }()

    func request(path: String, body: [String: Any]? = nil) throws -> URLRequest {
        try configuration.validate(key: key, needsModel: body != nil, needsConsent: body != nil)
        var request = URLRequest(url: try configuration.baseURL().appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func generationRequest(system: String, data: String, maxTokens: Int) throws -> URLRequest {
        var body: [String: Any] = [
            "model": configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [["role": "system", "content": system], ["role": "user", "content": data]],
            "stream": configuration.stream
        ]
        switch configuration.provider {
        case .openAI:
            // Model-specific sampling fields are deliberately omitted.
            body["max_completion_tokens"] = maxTokens
            body["store"] = false
        case .deepSeek:
            body["max_tokens"] = maxTokens
            body["thinking"] = ["type": "disabled"]
        case .lmStudio:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0
        }
        return try request(path: "chat/completions", body: body)
    }

    func models() async throws -> [String] {
        do {
            let (data, response) = try await session.data(for: request(path: "models"))
            try Self.validateResponse(response)
            guard data.count <= Self.maximumBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["data"] as? [[String: Any]] else { throw AIServiceError.invalidOutput }
            return Array(Set(models.compactMap { model -> String? in
                // Do not offer models known to have no text output capability.
                if let modalities = model["output_modalities"] as? [String], !modalities.contains("text") { return nil }
                return model["id"] as? String
            }.filter { !$0.isEmpty })).sorted()
        } catch { throw Self.safeError(error) }
    }

    func complete(system: String, data: String, maxTokens: Int,
                  partial: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let request = try generationRequest(system: system, data: data, maxTokens: maxTokens)
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await Self.receive(request, session: session, partial: partial) }
                group.addTask {
                    try await Task.sleep(for: totalTimeout)
                    throw AIServiceError.timedOut
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw AIServiceError.invalidOutput }
                return value
            }
        } catch { throw Self.safeError(error) }
    }

    private static let maximumBytes = 4 * 1_024 * 1_024
    static func receive(_ request: URLRequest, session: URLSession, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validateResponse(response)
        let streaming = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") == true
        if !streaming {
            var buffer = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                guard buffer.count <= Self.maximumBytes else { throw AIServiceError.invalidOutput }
            }
            let value = try AIChatResponseParser.json(buffer)
            partial(value)
            return value
        }
        var parser = AIChatResponseParser()
        var eventLines: [String] = []
        var receivedBytes = 0
        var lineBytes = Data()
        func consumeLine() throws {
            if lineBytes.last == 13 { lineBytes.removeLast() }
            guard var line = String(data: lineBytes, encoding: .utf8) else { throw AIServiceError.invalidOutput }
            lineBytes.removeAll(keepingCapacity: true)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.isEmpty {
                if !eventLines.isEmpty {
                    try parser.consume(eventLines.joined(separator: "\n"))
                    eventLines.removeAll(keepingCapacity: true)
                    partial(parser.content)
                }
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                eventLines.append(value)
            }
        }
        // AsyncBytes.lines omits empty lines; SSE needs them as event delimiters.
        for try await byte in bytes {
            try Task.checkCancellation()
            receivedBytes += 1
            guard receivedBytes <= Self.maximumBytes else { throw AIServiceError.invalidOutput }
            if byte == 10 {
                try consumeLine()
                if parser.done { break }
            } else { lineBytes.append(byte) }
        }
        if !lineBytes.isEmpty { try consumeLine() }
        if !eventLines.isEmpty { try parser.consume(eventLines.joined(separator: "\n")) }
        return try parser.result()
    }

    private static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidOutput }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw AIServiceError.redirect
        case 401, 403: throw AIServiceError.authentication
        case 400, 404, 422: throw AIServiceError.modelUnavailable
        case 429: throw AIServiceError.rateLimited
        default: throw AIServiceError.http(http.statusCode)
        }
    }
    private static func safeError(_ error: Error) -> Error {
        // Never expose arbitrary server error bodies, request URLs or keys in UI/logs.
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if error is AIServiceError { return error }
        if let network = error as? URLError {
            return network.code == .timedOut ? AIServiceError.timedOut : AIServiceError.unreachable
        }
        return AIServiceError.invalidOutput
    }
}

/// The caller may show partial text, but only a complete, single text choice is applicable.
struct AIChatResponseParser {
    private(set) var content = ""
    private(set) var done = false
    private var stopped = false
    mutating func consume(_ payload: String) throws {
        guard !done else { throw AIServiceError.invalidOutput }
        if payload == "[DONE]" { done = true; return }
        guard let data = payload.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["error"] == nil,
              let choices = event["choices"] as? [[String: Any]] else { throw AIServiceError.invalidOutput }
        if choices.isEmpty { return } // Usage-only event.
        guard choices.count == 1, let choice = choices.first,
              (choice["index"] as? Int ?? 0) == 0 else { throw AIServiceError.invalidOutput }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        try Self.validateMessage(delta)
        if let text = delta["content"] as? String, !text.isEmpty {
            guard !stopped else { throw AIServiceError.invalidOutput }
            content += text
        }
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop" else { throw AIServiceError.invalidOutput }
            stopped = true
        }
    }
    func result() throws -> String {
        guard done, stopped, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.invalidOutput
        }
        return content
    }
    static func json(_ data: Data) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["error"] == nil,
              let choices = value["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIServiceError.invalidOutput }
        try validateMessage(message)
        return text
    }
    private static func validateMessage(_ message: [String: Any]) throws {
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AIServiceError.invalidOutput }
        if let calls = message["tool_calls"] as? [Any], !calls.isEmpty { throw AIServiceError.invalidOutput }
        if message["function_call"] != nil { throw AIServiceError.invalidOutput }
        // reasoning_content is deliberately ignored.
    }
}
