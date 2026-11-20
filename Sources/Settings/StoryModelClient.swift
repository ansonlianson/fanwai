import Foundation

enum StoryModelError: String, Error, Codable, Sendable {
    case invalidKey = "密钥无效", insufficientBalance = "余额不足", connection = "连不上", unavailableModel = "模型不可用"

    static func classify(status: Int, data: Data) -> Self {
        // Read the provider's code for classification; never retain or surface
        // its message, which can echo a credential or an Authorization header.
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"] as? [String: Any] ?? root ?? [:]
        let code = [error["code"], error["type"], error["message"]]
            .compactMap { $0.map { String(describing: $0).lowercased() } }.joined(separator: " ")
        if status == 402 || ["insufficient_quota", "insufficient_balance", "credit balance", "balance insufficient", "arrearage", "accountquotaexceeded", "余额不足"].contains(where: code.contains) { return .insufficientBalance }
        if status == 401 || code.contains("invalid_api_key") || code.contains("authentication_error") { return .invalidKey }
        if status == 404 || ["model_not_found", "modelnotopen", "invalidmodel", "model_not_available", "permission_error"].contains(where: code.contains) { return .unavailableModel }
        if status == 403 { return .invalidKey }
        if status == 400 || status == 422 { return .unavailableModel }
        return .connection
    }
}

struct StoryModelUsage: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var cachedInputTokens: Int = 0
    var reasoningTokens: Int = 0
}
struct StoryModelReply: Codable, Sendable {
    let text: String
    let usage: StoryModelUsage?
    let model: String
}
protocol StoryModelClient: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws -> StoryModelReply
    func models() async throws -> [String]
}

struct StoryModelEndpoint: Codable, Equatable, Sendable {
    enum API: String, Codable, Sendable { case openAI, anthropic, responses }
    let api: API
    let baseURL: String
    let model: String
    var modelsPath: String? = "models"

    func url(_ path: String) throws -> URL {
        guard var base = URL(string: baseURL), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { throw StoryModelError.connection }
        // Accept the complete Messages URL prescribed in §8.2 as well as /v1.
        if base.lastPathComponent == "messages" { base.deleteLastPathComponent() }
        return base.appendingPathComponent(path)
    }
}

/// Not Codable. The client keeps this in memory for the duration of a job.
struct StoryModelCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    var description: String { "<redacted>" }
    var debugDescription: String { description }
}

struct StoryModelHTTP: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let load: Loader
    init(load: @escaping Loader = { request in
        let (data, response) = try await StoryModelHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StoryModelError.connection }
        return (data, http)
    }) { self.load = load }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90; configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: StoryModelNoRedirects(), delegateQueue: nil)
    }()

    func send(_ request: URLRequest, modelList: Bool = false) async throws -> Data? {
        let observedStart = Date().timeIntervalSince1970
        do {
            let (data, response) = try await load(request)
            if EvalPerformance.enabled && !modelList {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let usage = object?["usage"] as? [String: Any] ?? [:]
                var row = ["event":"modelHTTP", "host":request.url?.host ?? "", "status":String(response.statusCode),
                    "start":String(observedStart), "end":String(Date().timeIntervalSince1970)]
                for field in ["prompt_tokens", "completion_tokens", "input_tokens", "output_tokens", "prompt_cache_hit_tokens", "prompt_cache_miss_tokens", "total_tokens"] {
                    if let number = usage[field] as? NSNumber { row[field] = number.stringValue }
                }
                if let details = usage["input_tokens_details"] as? [String: Any], let count = details["cached_tokens"] as? NSNumber { row["cached_tokens"] = count.stringValue }
                EvalPerformance.record(row)
            }
            guard response.url == request.url, data.count <= 2_000_000 else { throw StoryModelError.connection }
            if modelList && [404, 405, 501].contains(response.statusCode) { return nil }
            guard (200...299).contains(response.statusCode) else { throw StoryModelError.classify(status: response.statusCode, data: data) }
            return data
        } catch let error as StoryModelError { throw error }
        catch {
            if EvalPerformance.enabled && !modelList {
                EvalPerformance.record(["event":"modelTransportFailure", "host":request.url?.host ?? "",
                    "start":String(observedStart), "end":String(Date().timeIntervalSince1970)])
            }
            throw StoryModelError.connection
        }
    }
}

struct OpenAICompatibleClient: StoryModelClient {
    var allowsThinking = false
    let endpoint: StoryModelEndpoint
    let credential: StoryModelCredential
    var http = StoryModelHTTP()

    private func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard !credential.value.isEmpty else { throw StoryModelError.invalidKey }
        var request = URLRequest(url: try endpoint.url(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue("Bearer " + credential.value, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        return request
    }
    func complete(system: String, user: String, maxTokens: Int = 4096) async throws -> StoryModelReply {
        var body: [String: Any] = ["model": endpoint.model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]], "stream": false]
        if endpoint.baseURL.contains("api.openai.com") { body["max_completion_tokens"] = maxTokens; body["store"] = false }
        else if endpoint.baseURL.contains("xiaomimimo.com") { body["max_completion_tokens"] = maxTokens }
        else { body["max_tokens"] = maxTokens }
        // Each call is independent; no reasoning history or tool calls are sent.
        if !allowsThinking && (endpoint.baseURL.contains("xiaomimimo.com") || endpoint.baseURL.contains("api.deepseek.com") || endpoint.baseURL.contains(TrialAccess.relayHost) || endpoint.baseURL.contains("volces.com")) { body["thinking"] = ["type": "disabled"] }
        if endpoint.baseURL.contains("aliyuncs.com") { body["enable_thinking"] = allowsThinking }
        guard let data = try await http.send(request("chat/completions", body: body)) else { throw StoryModelError.connection }
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            struct Usage: Decodable {
                struct Detail: Decodable { let cached_tokens: Int?; let reasoning_tokens: Int? }
                let prompt_tokens: Int; let completion_tokens: Int; let total_tokens: Int
                let prompt_tokens_details: Detail?; let completion_tokens_details: Detail?
            }
            let choices: [Choice]; let usage: Usage?; let model: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let choice = reply.choices.first else { throw StoryModelError.unavailableModel }
        let content = choice.message.content ?? ""
        return StoryModelReply(text: StoryModelJSON.finalText(content), usage: reply.usage.map {
            StoryModelUsage(inputTokens: $0.prompt_tokens, outputTokens: $0.completion_tokens, totalTokens: $0.total_tokens,
                            cachedInputTokens: $0.prompt_tokens_details?.cached_tokens ?? 0, reasoningTokens: $0.completion_tokens_details?.reasoning_tokens ?? 0)
        }, model: reply.model ?? endpoint.model)
    }
    func models() async throws -> [String] {
        guard let path = endpoint.modelsPath, let data = try await http.send(request(path), modelList: true) else { return [] }
        return try StoryModelJSON.modelIDs(data)
    }
}

struct AnthropicClient: StoryModelClient {
    let endpoint: StoryModelEndpoint
    let credential: StoryModelCredential
    var http = StoryModelHTTP()
    private func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard !credential.value.isEmpty else { throw StoryModelError.invalidKey }
        var request = URLRequest(url: try endpoint.url(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue("Bearer " + credential.value, forHTTPHeaderField: "Authorization")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        return request
    }
    func complete(system: String, user: String, maxTokens: Int = 4096) async throws -> StoryModelReply {
        let body: [String: Any] = ["model": endpoint.model, "system": system, "messages": [["role": "user", "content": user]], "max_tokens": maxTokens, "stream": false]
        guard let data = try await http.send(request("messages", body: body)) else { throw StoryModelError.connection }
        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int; let cache_read_input_tokens: Int?; let cache_creation_input_tokens: Int? }
            let content: [Block]; let model: String; let usage: Usage?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw StoryModelError.unavailableModel }
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        return .init(text: StoryModelJSON.finalText(text), usage: reply.usage.map {
            let cached = $0.cache_read_input_tokens ?? 0, created = $0.cache_creation_input_tokens ?? 0
            return .init(inputTokens: $0.input_tokens + cached + created, outputTokens: $0.output_tokens,
                         totalTokens: $0.input_tokens + cached + created + $0.output_tokens, cachedInputTokens: cached)
        }, model: reply.model)
    }
    func models() async throws -> [String] {
        guard let data = try await http.send(request("models"), modelList: true) else { return [] }
        return try StoryModelJSON.modelIDs(data)
    }
}

enum StoryModelJSON {
    static func finalText(_ text: String) -> String {
        var result = text
        for tag in ["think", "thinking", "reasoning"] {
            result = result.replacingOccurrences(of: "(?is)<" + tag + ">.*?</" + tag + ">", with: "", options: .regularExpression)
            if let unfinished = result.range(of: "<" + tag + ">", options: .caseInsensitive) { result = String(result[..<unfinished.lowerBound]) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Decode a balanced object/array, respecting quoted braces and escapes.
    /// Surrounding Markdown or explanatory text is not part of the payload.
    static func decode<T: Decodable>(_ type: T.Type, text: String) throws -> T {
        let chars = Array(finalText(text))
        for start in chars.indices where chars[start] == "{" || chars[start] == "[" {
            var stack: [Character] = [], quoted = false, escaped = false
            for i in start..<chars.count {
                let c = chars[i]
                if quoted {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
                    continue
                }
                if c == "\"" { quoted = true }
                else if c == "{" || c == "[" { stack.append(c) }
                else if c == "}" || c == "]" {
                    guard let opener = stack.popLast(), (opener == "{" && c == "}") || (opener == "[" && c == "]") else { break }
                    if stack.isEmpty {
                        if let value = try? JSONDecoder().decode(type, from: Data(String(chars[start...i]).utf8)) { return value }
                        break
                    }
                }
            }
        }
        throw StoryModelError.unavailableModel
    }
    static func modelIDs(_ data: Data) throws -> [String] {
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw StoryModelError.unavailableModel }
        return Array(Set(list.data.map(\.id).filter { !$0.isEmpty })).sorted()
    }
}

private final class StoryModelNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
