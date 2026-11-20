import XCTest
@testable import Pianwai

final class StoryModelClientTests: XCTestCase {
    func testEmptyFinalContentPreservesBilledReasoningUsage() async throws {
        let client = OpenAICompatibleClient(allowsThinking: true, endpoint: .init(api: .openAI, baseURL: "https://api.xiaomimimo.com/v1", model: "mimo-v2.6-pro"), credential: .init(value: "fixture"), http: .init { request in
            (Data(#"{"model":"mimo-v2.6-pro","choices":[{"message":{"content":null,"reasoning_content":"discard"}}],"usage":{"prompt_tokens":9,"completion_tokens":16384,"total_tokens":16393,"completion_tokens_details":{"reasoning_tokens":16384}}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let reply = try await client.complete(system: "check", user: "fixture", maxTokens: 16384)
        XCTAssertEqual(reply.text, "")
        XCTAssertEqual(reply.usage?.reasoningTokens, 16384)
        XCTAssertEqual(reply.usage?.totalTokens, 16393)
    }
    func testOpenAIContractFinalOnlyUsageModelsAndTolerantJSON() async throws {
        let backend = ModelHTTPFixture()
        let client = OpenAICompatibleClient(endpoint: .init(api: .openAI, baseURL: "https://api.openai.com/v1", model: "fixture"),
                                           credential: .init(value: "test-credential"), http: .init(load: { try await backend.load($0) }))
        let reply = try await client.complete(system: "EXACT\n", user: "公开资料", maxTokens: 200)
        XCTAssertEqual(reply.text, "```json\n{\"facts\":[]}\n```")
        XCTAssertEqual(reply.usage?.totalTokens, 12)
        struct Facts: Decodable { let facts: [String] }
        XCTAssertTrue(try StoryModelJSON.decode(Facts.self, text: "说明：" + reply.text + "结束").facts.isEmpty)
        let models = try await client.models(); XCTAssertEqual(models, ["fixture"])
        let requests = await backend.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(requests[0].url?.path, "/v1/chat/completions")
        XCTAssertEqual(requests[1].url?.path, "/v1/models")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "EXACT\n")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 200)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["user"]); XCTAssertNil(body["tools"])
        XCTAssertFalse(reply.text.contains("private reasoning"))
        XCTAssertEqual(StoryModelJSON.finalText("<think>unfinished {\"facts\":[]}"), "")
    }
    func testAnthropicBlocksAndFourSafeErrorClasses() async throws {
        let backend = ModelHTTPFixture(anthropic: true)
        let client = AnthropicClient(endpoint: .init(api: .anthropic, baseURL: "https://api.anthropic.com/v1/messages", model: "fixture"),
                                     credential: .init(value: "test-credential"), http: .init(load: { try await backend.load($0) }))
        let reply = try await client.complete(system: "EXACT\n", user: "公开资料", maxTokens: 200)
        XCTAssertEqual(reply.text, "{\"facts\":[]}")
        XCTAssertEqual(reply.usage?.totalTokens, 20)
        let requests = await backend.requests
        XCTAssertEqual(requests[0].url?.path, "/v1/messages")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        for (status, body, expected) in [(401, "{}", StoryModelError.invalidKey),
                                         (429, #"{"error":{"code":"insufficient_quota"}}"#, .insufficientBalance),
                                         (404, "{}", .unavailableModel), (503, "{}", .connection)] {
            XCTAssertEqual(StoryModelError.classify(status: status, data: Data(body.utf8)), expected)
        }
        let fallback = OpenAICompatibleClient(endpoint: .init(api: .openAI, baseURL: "https://example.org/v1", model: "fixture"),
            credential: .init(value: "test-credential"), http: .init { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 405, httpVersion: nil, headerFields: nil)!) })
        let models = try await fallback.models(); XCTAssertTrue(models.isEmpty)
    }
}

private actor ModelHTTPFixture {
    let anthropic: Bool
    var requests: [URLRequest] = []
    init(anthropic: Bool = false) { self.anthropic = anthropic }
    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data: Data
        if request.httpMethod != "POST" { data = Data(#"{"data":[{"id":"fixture"}]}"#.utf8) }
        else if anthropic { data = Data(#"{"model":"fixture","content":[{"type":"thinking","thinking":"discard"},{"type":"text","text":"{\"facts\":[]}"}],"usage":{"input_tokens":8,"output_tokens":2,"cache_read_input_tokens":10}}"#.utf8) }
        else { data = Data(#"{"model":"fixture","choices":[{"message":{"reasoning_content":"private reasoning","content":"<think>private reasoning</think>```json\n{\"facts\":[]}\n```"}}],"usage":{"prompt_tokens":8,"completion_tokens":4,"total_tokens":12}}"#.utf8) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
