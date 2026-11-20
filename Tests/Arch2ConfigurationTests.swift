import XCTest
@testable import Pianwai

@MainActor final class Arch2ConfigurationTests: XCTestCase {
    func testDatabaseFactsRemainNavigableWithoutAnyModelConfiguration() throws {
        let suite = "Arch2.public-facts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StoryModelSettings(defaults: defaults)
        XCTAssertNil(settings.configuration())
        let catalog = CatalogStore(cacheURL: nil)
        let root = WorkID(rawValue: "local:arch2-recording")!, film = WorkID(rawValue: "local:arch2-film")!
        try catalog.merge(.init(works: [
            .init(id: root, title: "录音", creator: "", kind: "歌曲", art: "", detail: "", url: nil),
            .init(id: film, title: "电影", creator: "", kind: "电影", art: "", detail: "", url: nil)
        ], relations: [.init(from: root, to: film, predicate: .usedIn, label: "用于", inverseLabel: "采用音乐",
            source: .init(title: "MusicBrainz", url: "https://musicbrainz.org/recording/00000000-0000-0000-0000-000000000001"), researchRoot: root)]))
        XCTAssertEqual(DiscoveryNavigation.leads(from: root.rawValue, catalog: catalog, known: [:], provider: nil).map(\.id), [film.rawValue])
        XCTAssertNil(settings.client())
    }

    func testProviderAndCustomServerKeysNeverCrossRequests() async throws {
        let suite = "Arch2.keys." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        let backend = Arch2ModelHTTP()
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: .init { try await backend.load($0) })
        defer { settings.removeKey(); defaults.removePersistentDomain(forName: suite); try? chain.remove("deepseek") }
        settings.selectProvider("deepseek"); settings.saveKey("unit-deepseek")
        settings.selectProvider("custom"); settings.setAddress("https://first.example/v1")
        settings.selectModel("unit-model"); settings.saveKey("unit-first")
        _ = try await settings.client()?.complete(system: "test", user: "test", maxTokens: 16)
        settings.setAddress("https://second.example/v1")
        XCTAssertFalse(settings.hasKey); XCTAssertNil(settings.configuration())
        settings.saveKey("unit-second")
        _ = try await settings.client()?.complete(system: "test", user: "test", maxTokens: 16)
        settings.setAddress("https://first.example/v1")
        XCTAssertTrue(settings.hasKey)
        settings.removeKey()
        settings.selectProvider("deepseek")
        _ = try await settings.client()?.complete(system: "test", user: "test", maxTokens: 16)
        let posts = await backend.posts
        XCTAssertEqual(posts.map(\.host), ["first.example", "second.example", "api.deepseek.com"])
        XCTAssertEqual(posts.map(\.authorization), ["Bearer unit-first", "Bearer unit-second", "Bearer unit-deepseek"])
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("unit-first"))
        settings.selectProvider("custom"); settings.setAddress("https://second.example/v1"); settings.removeKey()
    }

    func testConnectionConfirmsAnExecutedSearchRatherThanAnOKReply() async throws {
        let suite = "Arch2.probe." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        let backend = Arch2ModelHTTP()
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: .init { try await backend.load($0) })
        defer { settings.removeKey(); defaults.removePersistentDomain(forName: suite) }
        settings.selectProvider("custom"); settings.setAddress("https://first.example/v1")
        settings.selectModel("unit-model"); settings.saveKey("unit-probe")
        XCTAssertEqual(settings.endpoint?.api, .responses, "自定义 speaks Responses; the user does not pick an interface")
        await settings.testConnection()
        XCTAssertEqual(settings.connectionResult, "连接正常，可以联网查找")
    }

    /// anson 11-18: only services the app can search with; their model lists keep only models that can search.
    func testOnlySearchCapableServicesAndModelsAreOffered() throws {
        let suite = "Arch2.searchable." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StoryModelSettings(defaults: defaults, keychain: .init(service: suite))
        XCTAssertEqual(Set(settings.presets.map(\.id)), ["deepseek", "openai", "custom"])
        XCTAssertEqual(settings.presets.first { $0.id == "openai" }?.api, .responses)
        XCTAssertEqual(StoryModelSettings.customAPI(address: "https://api.deepseek.com"), .openAI)
        XCTAssertEqual(StoryModelSettings.customAPI(address: "https://pool.example/v1"), .responses)
        let listed = ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-4o-mini-tts", "text-embedding-3-large", "gpt-image-2", "whisper-1",
                      "gpt-4o-realtime-preview", "gpt-4o-search-preview", "o1-mini", "gpt-4", "gpt-4.1", "o4-mini"]
        XCTAssertEqual(listed.filter { StoryModelSettings.searchable(model: $0, api: .responses) },
                       ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-4.1", "o4-mini"])
        XCTAssertTrue(StoryModelSettings.searchable(model: "deepseek-v4-pro", api: .openAI))
    }
}

private actor Arch2ModelHTTP {
    struct Post: Sendable { let host: String; let authorization: String }
    var posts: [Post] = []
    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" ? 200 : 404, httpVersion: nil, headerFields: nil)!
        guard request.httpMethod == "POST" else { return (Data(), response) }
        posts.append(.init(host: request.url!.host!, authorization: request.value(forHTTPHeaderField: "Authorization") ?? ""))
        let native = #"{"status":"completed","model":"unit-model","output":[{"type":"web_search_call","action":{"type":"search","sources":[{"url":"https://example.com"}]}},{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#
        let chat = #"{"model":"unit-model","choices":[{"message":{"content":"OK"}}]}"#
        return (Data((request.url!.path.hasSuffix("responses") ? native : chat).utf8), response)
    }
}
