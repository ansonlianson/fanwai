import XCTest
import Security
@testable import Pianwai

@MainActor final class StoryModelSettingsTests: XCTestCase {
    func testCustomModelFallbackAndThinkingOnlyWhenChecking() async throws {
        let suite = "Pianwai.SettingsQuality." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        let backend = QualitySettingsHTTP()
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: .init { try await backend.load($0) })
        defer { settings.removeKey(); defaults.removePersistentDomain(forName: suite); try? chain.remove("deepseek") }
        settings.selectProvider("deepseek"); settings.saveKey("offline-only")
        _ = try await settings.client()?.complete(system: "write", user: "fixture", maxTokens: 8)
        _ = try await settings.client(checking: true)?.complete(system: "check", user: "fixture", maxTokens: 16384)
        let posts = await backend.posts
        XCTAssertEqual(posts.map { $0.model }, ["deepseek-flash", "deepseek-flash"])
        XCTAssertEqual(posts.map { $0.disabled }, [true, false])
        settings.selectProvider("custom"); settings.setAddress("https://example.org/v1")
        settings.selectModel("my-local-model"); settings.saveKey("offline-custom-only")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(settings.usesManualModel)
        XCTAssertEqual(settings.model, "my-local-model")
        XCTAssertEqual(settings.availableModels, ["my-local-model"], "no ready-made list: only what is set, until the service lists its own")
        _ = try await settings.client(checking: true)?.complete(system: "check", user: "fixture", maxTokens: 8)
        let customPosts = await backend.posts
        XCTAssertEqual(customPosts.last?.model, "my-local-model")
    }
    func testKeychainLocalOnlySaveReadReplaceRemoveAndPreferences() throws {
        let service = "com.anson.pianwai.tests.story-model." + UUID().uuidString
        let chain = StoryModelKeychain(service: service)
        defer { try? chain.remove("deepseek") }
        XCTAssertNil(try chain.read("deepseek"))
        try chain.save(.init(value: "fixture-not-secret-abcd"), account: "deepseek")
        XCTAssertEqual(try chain.read("deepseek")?.value, "fixture-not-secret-abcd")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "deepseek", kSecReturnAttributes as String: true]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        let suite = "Pianwai.ModelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: .init { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        settings.selectProvider("deepseek")
        XCTAssertEqual(settings.maskedKey, "••••••••")
        settings.selectModel("fixture")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("fixture-not-secret-abcd"))
        try chain.save(.init(value: "replacement-efgh"), account: "deepseek")
        XCTAssertEqual(try chain.read("deepseek")?.value, "replacement-efgh")
        settings.removeKey(); XCTAssertFalse(settings.hasKey); XCTAssertNil(try chain.read("deepseek"))
    }

}
private actor QualitySettingsHTTP {
    struct Post: Sendable { let model: String; let disabled: Bool }
    var posts: [Post] = []
    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if request.httpMethod != "POST" { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        posts.append(.init(model: body["model"] as? String ?? "", disabled: (body["thinking"] as? [String: String])?["type"] == "disabled"))
        let native = #"{"status":"completed","model":"fixture","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#
        let chat = #"{"choices":[{"message":{"content":"OK"}}]}"#
        return (Data((request.url!.path.hasSuffix("responses") ? native : chat).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private actor ModelJobGate {
    var active: Set<String> = [], started: Set<String> = []
    var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    func run(_ id: String) async {
        active.insert(id); started.insert(id)
        await withCheckedContinuation { continuations[id] = $0 }
        active.remove(id)
    }
    func release(_ id: String) { continuations.removeValue(forKey: id)?.resume() }
}
