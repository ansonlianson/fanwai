import XCTest
@testable import Pianwai

/// 体验码 (ONBOARDING/BETA-TRIAL.md): a pass stands in while the reader has no service of their own,
/// its lookups go to the relay and nowhere else, and what it found stays readable afterwards.
@MainActor final class TrialAccessTests: XCTestCase {
    private func settings(pass: TrialAccess, key: String? = nil) throws -> (StoryModelSettings, () -> Void) {
        let suite = "Pianwai.Trial." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, pass: pass, http: .init { _ in throw URLError(.notConnectedToInternet) })
        if let key { settings.selectProvider("deepseek"); settings.saveKey(key) }
        return (settings, { settings.removeKey(); defaults.removePersistentDomain(forName: suite); try? chain.remove("deepseek") })
    }
    private func pass(_ remaining: Int, of total: Int) throws -> TrialAccess {
        TrialAccess(token: TrialAccess.tokenPrefix + "test", total: total, used: total - remaining,
                    defaults: try XCTUnwrap(UserDefaults(suiteName: "Pianwai.TrialPass." + UUID().uuidString)))
    }

    func testAPassStandsInUntilTheReaderHasTheirOwnService() throws {
        let (trial, clean) = try settings(pass: try pass(7, of: 10)); defer { clean() }
        let configuration = try XCTUnwrap(trial.configuration())
        XCTAssertTrue(configuration.isTrial)
        XCTAssertTrue(configuration.isDeepSeek, "the relay offers DeepSeek's search tool and chat interface")
        XCTAssertEqual(configuration.endpoint.baseURL, "https://api.fanwai.xyz/ds")
        XCTAssertEqual(configuration.endpoint.model, "deepseek-flash")
        XCTAssertNil(configuration.price, "the reader is not charged, so no cost is shown for these lookups")
        XCTAssertNil(trial.configuration(checking: true), "测试连接 is for the reader's own service")
        XCTAssertFalse(trial.hasKey, "深挖 and the paid extras stay off on a pass")

        let (own, cleanOwn) = try settings(pass: try pass(7, of: 10), key: "sk-own-key-for-tests-only"); defer { cleanOwn() }
        XCTAssertEqual(own.configuration()?.isTrial, false, "their own key comes first")
    }

    func testWhatAPassFoundIsFiledWhereTheirOwnDeepSeekKeyWouldLook() throws {
        let (trial, clean) = try settings(pass: try pass(7, of: 10)); defer { clean() }
        let (own, cleanOwn) = try settings(pass: TrialAccess(token: nil, total: 0, used: 0, defaults: .init(suiteName: "Pianwai.TrialNone")!),
                                           key: "sk-own-key-for-tests-only"); defer { cleanOwn() }
        XCTAssertEqual(trial.researchNamespace, own.researchNamespace)
        // A pass that has run out looks nothing up, and still shows what it found.
        let (spent, cleanSpent) = try settings(pass: try pass(0, of: 10)); defer { cleanSpent() }
        XCTAssertNil(spent.configuration())
        XCTAssertEqual(spent.researchNamespace, own.researchNamespace)
    }

    func testOnlyAPassGoesToTheRelayAndOnlyALookupIsMarked() async {
        XCTAssertEqual(TrialRelay.toolURL("search", credential: "sk-someone-elses").absoluteString, "https://api.deepseek.com/v1/tools/search")
        XCTAssertEqual(TrialRelay.toolURL("fetch", credential: "fwt_abc").absoluteString, "https://api.fanwai.xyz/ds/v1/tools/fetch")
        var outside = URLRequest(url: URL(string: "https://api.fanwai.xyz/ds/chat/completions")!)
        TrialRelay.mark(&outside)
        XCTAssertNil(outside.value(forHTTPHeaderField: "X-Fanwai-Song"), "nothing is marked outside a lookup")
        let lookup = TrialRelay.Lookup(subjectID: "apple:song:1", title: "晴天", creator: "周杰伦")
        await TrialRelay.$lookup.withValue(lookup) {
            var relay = URLRequest(url: URL(string: "https://api.fanwai.xyz/ds/chat/completions")!)
            var deepseek = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
            // Searches run in child tasks: the mark has to follow them there.
            await withTaskGroup(of: Void.self) { group in group.addTask { XCTAssertEqual(TrialRelay.lookup?.header, lookup.header) } }
            TrialRelay.mark(&relay); TrialRelay.mark(&deepseek)
            XCTAssertEqual(relay.value(forHTTPHeaderField: "X-Fanwai-Song"), lookup.header)
            XCTAssertEqual(relay.value(forHTTPHeaderField: "X-Fanwai-Title")?.removingPercentEncoding, "晴天 — 周杰伦")
            XCTAssertNil(deepseek.value(forHTTPHeaderField: "X-Fanwai-Song"), "a song's name goes to the relay only on a pass")
        }
        XCTAssertNotEqual(TrialRelay.Lookup(subjectID: "apple:song:1", title: "", creator: "").run, lookup.run, "each lookup is its own run")
        XCTAssertEqual(TrialRelay.Lookup(subjectID: "apple:song:1", title: "", creator: "").song, lookup.song, "of the same song")
    }

    func testAPassCountsDownAndStopsWhenTheRelaySaysSo() throws {
        let access = try pass(2, of: 10)
        XCTAssertTrue(access.usable)
        access.note(remaining: 1); XCTAssertEqual(access.remaining, 1)
        access.note(remaining: 0); XCTAssertFalse(access.usable)
        access.note(remaining: 99); XCTAssertEqual(access.remaining, 0, "an answer cannot give more than the pass holds")
        access.forget(); XCTAssertFalse(access.hasPass)
    }
}
