import XCTest
@testable import Pianwai

final class InternalStoryTests: XCTestCase {
    func testResponsesUsesInternalEndpointAndOnlyCompletedFinalText() async throws {
        let client = OpenAIResponsesClient(endpoint: .init(api: .responses, baseURL: "https://example.org/v1", model: "fixture-model"),
            credential: .init(value: "fixture"), http: .init { request in
                XCTAssertEqual(request.url?.absoluteString, "https://example.org/v1/responses")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(body["store"] as? Bool, false)
                XCTAssertEqual(body["stream"] as? Bool, false)
                XCTAssertEqual(body["instructions"] as? String, "instructions")
                XCTAssertEqual(body["max_output_tokens"] as? Int, 500)
                XCTAssertNil(body["tools"])
                return (Data(#"{"model":"gpt-6.1-terra","status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"{\"candidates\":[]}"}]}],"usage":{"input_tokens":20,"output_tokens":12,"total_tokens":32,"input_tokens_details":{"cached_tokens":10},"output_tokens_details":{"reasoning_tokens":5}}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let result = try await client.complete(system: "instructions", user: "materials", maxTokens: 500)
        XCTAssertEqual(result.text, #"{"candidates":[]}"#)
        XCTAssertEqual(result.usage?.totalTokens, 32)
        XCTAssertEqual(result.usage?.cachedInputTokens, 10)
        XCTAssertEqual(result.usage?.reasoningTokens, 5)
        let incomplete = OpenAIResponsesClient(endpoint: client.endpoint, credential: client.credential, http: .init { request in
            (Data(#"{"model":"fixture","status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"unfinished"}]}],"usage":{"input_tokens":10,"output_tokens":100,"total_tokens":110}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let rejected = try await incomplete.complete(system: "x", user: "x", maxTokens: 100)
        XCTAssertEqual(rejected.text, ""); XCTAssertEqual(rejected.usage?.totalTokens, 110)
    }

    @MainActor func testInternalPresetFirstLaunchAndPersistentProviderChoiceWithoutPreferenceKeyLeak() throws {
        let suite = "Pianwai.InternalTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = InternalStoryModel.Access(preset: .init(id: "internal", name: "GPT（开发）", api: .responses,
            baseURL: "https://example.org/v1", models: ["fixture-model"], modelsPath: nil, verifiedAt: "", source: ""),
            credential: .init(value: "fixture-secret"))
        let offline = StoryModelHTTP { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        // 0.5.25 (anson 2026-11-18): no built-in「GPT（开发）」; an internal build seeds the developer's
        // own service into 自定义 once, and the key stays in the bundle.
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: offline, internalAccess: access)
        XCTAssertFalse(settings.presets.contains { $0.id == "internal" })
        XCTAssertEqual(settings.preferences.providerID, "custom")
        XCTAssertEqual(settings.preferences.customAddress, "https://example.org/v1")
        XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(settings.endpoint?.api, .responses)
        XCTAssertEqual(settings.model, "fixture-model")
        XCTAssertEqual(settings.configuration()?.namespace, "gpt-fixture-model", "research saved under the old built-in choice stays readable")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("fixture-secret"))
        // The user's own address is theirs: the bundled key does not follow it.
        settings.setAddress("https://custom.example/v1"); settings.selectModel("user-model")
        XCTAssertFalse(settings.hasKey); XCTAssertNil(settings.client())
        let reopened = StoryModelSettings(defaults: defaults, keychain: chain, http: offline, internalAccess: access)
        XCTAssertEqual(reopened.preferences.providerID, "custom")
        XCTAssertEqual(reopened.preferences.customAddress, "https://custom.example/v1", "seeded once; a changed entry is not overwritten")
        XCTAssertEqual(reopened.endpoint?.api, .responses)
        // An older install that had chosen the built-in entry lands on the seeded 自定义.
        let old = try XCTUnwrap(UserDefaults(suiteName: suite + ".old")); defer { old.removePersistentDomain(forName: suite + ".old") }
        old.set(try JSONEncoder().encode(StoryModelSettings.Preferences(providerID: "internal")), forKey: "redesign.storyModel.preferences.v1")
        let migrated = StoryModelSettings(defaults: old, keychain: chain, http: offline, internalAccess: access)
        XCTAssertEqual(migrated.preferences.providerID, "custom"); XCTAssertNotNil(migrated.client())
        // Removing the key turns the bundled one off, across a relaunch.
        migrated.removeKey()
        XCTAssertFalse(migrated.hasKey)
        XCTAssertFalse(StoryModelSettings(defaults: old, keychain: chain, http: offline, internalAccess: access).hasKey)
    }

    @MainActor func testPublicSettingsHaveNoInternalPresetOrFirstProvider() throws {
        let suite = "Pianwai.PublicModelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StoryModelSettings(defaults: defaults)
        XCTAssertFalse(settings.presets.contains { $0.id == "internal" })
        XCTAssertEqual(settings.preferences.providerID, "")
        XCTAssertNil(settings.configuration()); XCTAssertNil(settings.client())
        if Bundle.main.object(forInfoDictionaryKey: "PianwaiInternal") as? String != "YES" {
            XCTAssertNil(InternalStoryModel.access())
        }
    }

    @MainActor func testCompleteStoriesKeepConsistentTypeAndAllowAccessibleOverflow() {
        let catalog = CatalogStore(cacheURL: nil)
        let stories = catalog.stories + ["pool", "jane", "actor"].compactMap(SeedNowContent.entity)
            .flatMap { NowStoryContent.stories(for: $0, catalog: catalog) }
            + [Story(id: "maximum", entityID: "fixture", title: "", body: String(repeating: "字", count: 400),
                     source: .init(title: "原文", url: "https://example.org/story"))]
        for story in stories {
            for size in [CGSize(width: 320, height: 480), CGSize(width: 402, height: 700), CGSize(width: 700, height: 300)] {
                for preferred: CGFloat in [18, 36] {
                    let layout = StoryReadingLayout.fitting(story: story, size: size, preferredBody: preferred)
                    XCTAssertEqual(layout.bodySize, preferred == 18 ? 18 : 21, "Story length must not choose the reading font")
                    XCTAssertGreaterThan(layout.measuredHeight, 0)
                }
            }
        }
        let normal = StoryReadingLayout.fitting(story: stories[0], size: .init(width: 420, height: 720), preferredBody: 17)
        XCTAssertLessThanOrEqual(normal.measuredHeight, 720, "The ordinary phone layout keeps reviewed prose on one page")
    }

    func testEditorialParagraphKeepsLengthAndSentenceGuardWithLegacyCompatibility() {
        let context = StoryContext(entityID: "fixture", entityName: "作品")
        func story(_ body: String, title: String = "") -> Story {
            .init(id: "test", entityID: "fixture", title: title, body: body,
                  source: .init(title: "原文", url: "https://example.org/story"))
        }
        XCTAssertTrue(StoryValidator().validate(story(String(repeating: "字", count: 400)), context: context).isValid)
        XCTAssertFalse(StoryValidator().validate(story(String(repeating: "字", count: 401)), context: context).isValid)
        XCTAssertFalse(StoryValidator().validate(story(String(repeating: "一句。", count: 11)), context: context).isValid)
        XCTAssertFalse(StoryValidator().validate(story(String(repeating: "字", count: 91), title: "旧格式"), context: context).isValid)
    }
}
