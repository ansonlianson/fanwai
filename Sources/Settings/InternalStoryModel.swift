import Foundation

/// Internal access exists only in a flagged build's private bundle resource.
/// No deployment address, model name or credential is a source-code default.
enum InternalStoryModel {
    struct Access: Sendable {
        let preset: StoryModelPreset
        let credential: StoryModelCredential
        var deepseekCredential: StoryModelCredential? = nil
    }
    static func access(bundle: Bundle = .main) -> Access? {
        guard bundle.object(forInfoDictionaryKey: "PianwaiInternal") as? String == "YES",
              let url = bundle.url(forResource: "InternalStoryAccess", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let address = values["baseURL"], let endpoint = URL(string: address), endpoint.scheme == "https",
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              let model = values["model"], !model.isEmpty,
              let key = values["credential"], !key.isEmpty else { return nil }
        let dsKey = values["deepseekCredential"].flatMap { !$0.isEmpty ? StoryModelCredential(value: $0) : nil }
        return .init(preset: .init(id: "internal", name: "GPT（开发）", api: .responses,
            baseURL: address, models: [model], modelsPath: nil, verifiedAt: "", source: ""),
            credential: .init(value: key), deepseekCredential: dsKey)
    }
    static var model: String { access()?.preset.models.first ?? "" }
    static var baseURL: String { access()?.preset.baseURL ?? "" }
    static func credential(bundle: Bundle = .main) -> StoryModelCredential? { access(bundle: bundle)?.credential }
}

struct OpenAIResponsesClient: StoryModelClient {
    let endpoint: StoryModelEndpoint
    let credential: StoryModelCredential
    var http = StoryModelHTTP()

    func complete(system: String, user: String, maxTokens: Int) async throws -> StoryModelReply {
        guard !credential.value.isEmpty else { throw StoryModelError.invalidKey }
        var request = URLRequest(url: try endpoint.url("responses"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer " + credential.value, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": endpoint.model, "instructions": system,
            "input": [["role": "user", "content": user]],
            "store": false, "stream": false, "max_output_tokens": maxTokens,
            "reasoning": ["effort": "low"]
        ], options: [.sortedKeys])
        guard let data = try await http.send(request) else { throw StoryModelError.connection }
        struct Reply: Decodable {
            struct Item: Decodable {
                struct Content: Decodable { let type: String; let text: String? }
                let type: String; let content: [Content]?
            }
            struct Usage: Decodable {
                struct Input: Decodable { let cached_tokens: Int? }
                struct Output: Decodable { let reasoning_tokens: Int? }
                let input_tokens: Int; let output_tokens: Int; let total_tokens: Int
                let input_tokens_details: Input?; let output_tokens_details: Output?
            }
            let model: String; let status: String; let output: [Item]; let usage: Usage?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw StoryModelError.unavailableModel }
        // Incomplete/refused output must not be accepted as a finished story.
        // Keep numeric billing even when the final text is empty.
        let text = reply.status == "completed" ? reply.output.filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }.filter { $0.type == "output_text" }.compactMap(\.text).joined(separator: "\n") : ""
        return .init(text: StoryModelJSON.finalText(text), usage: reply.usage.map {
            .init(inputTokens: $0.input_tokens, outputTokens: $0.output_tokens, totalTokens: $0.total_tokens,
                  cachedInputTokens: $0.input_tokens_details?.cached_tokens ?? 0,
                  reasoningTokens: $0.output_tokens_details?.reasoning_tokens ?? 0)
        }, model: reply.model)
    }
    /// The service's own list (GET …/models), like the chat interface; the chosen model when there is none.
    func models() async throws -> [String] {
        guard !credential.value.isEmpty else { throw StoryModelError.invalidKey }
        var request = URLRequest(url: try endpoint.url(endpoint.modelsPath ?? "models"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer " + credential.value, forHTTPHeaderField: "Authorization")
        guard let data = try? await http.send(request, modelList: true),
              let values = try? StoryModelJSON.modelIDs(data), !values.isEmpty else { return [] }
        return values
    }
}
