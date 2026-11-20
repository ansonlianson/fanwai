import Foundation
import Observation
import Security

/// 体验码 (Design/review/ONBOARDING/BETA-TRIAL.md): a friend of the developer enters a code and looks up a
/// fixed number of songs on the developer's DeepSeek account. The key never comes near the app: lookups go
/// to 番外's relay (Server/relay), which checks the pass, forwards the request and counts the song.
///
/// Free lookups WITHOUT a code need the phone itself checked (App Attest + DeviceCheck). That is not built:
/// the relay answers 501 for it and nothing here offers it.
@MainActor @Observable final class TrialAccess {
    static let shared = TrialAccess()
    /// No pass at all: what a settings object made for a test or a tool sees, whatever is in the keychain.
    static let none = TrialAccess(token: nil, total: 0, used: 0, defaults: UserDefaults(suiteName: "Pianwai.Trial.None") ?? .standard)
    nonisolated static let relay = "https://api.fanwai.xyz"
    nonisolated static let relayHost = "api.fanwai.xyz"
    /// A pass token, as opposed to a service's own key: requests carrying one go to the relay.
    nonisolated static let tokenPrefix = "fwt_"

    enum Redeemed: Equatable { case ok, notFound, tooManyDevices, disabled, tooManyAttempts, unreachable }

    private(set) var token: String?
    private(set) var total: Int
    private(set) var used: Int
    /// The relay's own switch, and this pass's.
    private(set) var enabled = true
    private(set) var dailyCapReached = false
    /// What the relay last said about codes being accepted at all (nil: not asked yet, or unreachable).
    private(set) var serviceOpen: Bool?
    /// The default model per service, when the relay names one (a service renames its models now and then).
    private(set) var defaultModels: [String: String] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let keychain: Bool
    nonisolated private static let service = "com.anson.pianwai.trial.v1"
    nonisolated private static let account = "pass"

    var hasPass: Bool { token != nil }
    var remaining: Int { max(0, total - used) }
    /// A new lookup may start on the pass.
    var usable: Bool { hasPass && remaining > 0 && enabled && !dailyCapReached }
    /// The code entry is shown: the relay has not said it is closed.
    var offered: Bool { serviceOpen != false }

    init(defaults: UserDefaults = .standard, session: URLSession = TrialAccess.plainSession, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults; self.session = session
        var stored: String? = nil, usesKeychain = true
        #if DEBUG && targetEnvironment(simulator)
        // Review: a pass that exists only in this launch, 「--ui-trial-pass=<remaining>/<total>」; nothing is sent.
        if let raw = arguments.first(where: { $0.hasPrefix("--ui-trial-pass=") }) {
            let parts = raw.dropFirst("--ui-trial-pass=".count).split(separator: "/").compactMap { Int($0) }
            if parts.count == 2 {
                defaults.set(parts[1], forKey: "trial.total.v2"); defaults.set(parts[1] - parts[0], forKey: "trial.used.v2")
                stored = Self.tokenPrefix + "review"
            }
            usesKeychain = false
        } else if arguments.contains("--ui-isolate-data") && !arguments.contains("--ui-trial-live") {
            if arguments.contains("--ui-reset") { defaults.removeObject(forKey: "trial.total.v2"); defaults.removeObject(forKey: "trial.used.v2") }
            usesKeychain = false
        } else if arguments.contains("--ui-reset") { Self.store(nil) }
        #endif
        keychain = usesKeychain
        token = stored ?? (usesKeychain ? Self.read() : nil)
        total = defaults.integer(forKey: "trial.total.v2")
        used = defaults.integer(forKey: "trial.used.v2")
    }

    /// A pass held in memory only, for tests and review: nothing is read from or written to the keychain.
    init(token: String?, total: Int, used: Int, defaults: UserDefaults, session: URLSession = TrialAccess.plainSession) {
        self.defaults = defaults; self.session = session; keychain = false
        self.token = token; self.total = total; self.used = used
    }

    // MARK: Talking to the relay

    nonisolated static let plainSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private struct Status: Decodable {
        let total: Int; let used: Int; let enabled: Bool; let dailyCapReached: Bool; let token: String?
    }
    private func request(_ path: String, body: [String: Any]? = nil, authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.relay + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if authorized, let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    private var live: Bool { keychain || token == nil }
    private func apply(_ status: Status) {
        total = status.total; used = status.used; enabled = status.enabled; dailyCapReached = status.dailyCapReached
        defaults.set(total, forKey: "trial.total.v2"); defaults.set(used, forKey: "trial.used.v2")
    }

    /// The code a friend was given. Spaces, lower case and a missing dash are the relay's to forgive.
    func redeem(_ code: String) async -> Redeemed {
        #if DEBUG && targetEnvironment(simulator)
        // Review: 「--ui-trial-codes」 answers without the network: FW-GOOD-CODE works, anything else does not.
        if ProcessInfo.processInfo.arguments.contains("--ui-trial-codes") {
            try? await Task.sleep(for: .milliseconds(500))
            guard code.uppercased().filter({ $0.isLetter || $0.isNumber }) == "FWGOODCODE" else { return .notFound }
            token = Self.tokenPrefix + "review"; apply(.init(total: 10, used: 0, enabled: true, dailyCapReached: false, token: nil))
            return .ok
        }
        #endif
        guard let (data, response) = try? await session.data(for: request("/v1/trial/redeem", body: ["code": code], authorized: false)),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200:
            guard let status = try? JSONDecoder().decode(Status.self, from: data), let fresh = status.token else { return .unreachable }
            token = fresh; if keychain { Self.store(fresh) }
            apply(status)
            return .ok
        case 404: return .notFound
        case 429: return .tooManyAttempts
        case 403: return Self.errorType(data) == "code_devices" ? .tooManyDevices : .disabled
        default: return .unreachable
        }
    }

    /// What is left on the pass, from the relay. Called on coming forward and after each lookup.
    func refresh() async {
        guard hasPass, live else { return }
        guard let (data, response) = try? await session.data(for: request("/v1/trial/pass")), let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { forget(); return }
        if let status = try? JSONDecoder().decode(Status.self, from: data) { apply(status) }
    }

    /// 默认模型名 and whether codes are accepted, for every reader; carries nothing about this one.
    func loadConfiguration() async {
        guard live else { return }
        struct Reply: Decodable {
            struct Trial: Decodable { let enabled: Bool }
            let trial: Trial?; let defaultModels: [String: String]?
        }
        guard let (data, _) = try? await session.data(for: request("/v1/config", authorized: false)),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        serviceOpen = reply.trial?.enabled; defaultModels = reply.defaultModels ?? [:]
    }

    /// From a relay answer's 「X-Fanwai-Remaining」.
    func note(remaining: Int) {
        guard hasPass, remaining >= 0, remaining <= total else { return }
        used = total - remaining; defaults.set(used, forKey: "trial.used.v2")
    }
    func forget() {
        token = nil; total = 0; used = 0
        if keychain { Self.store(nil) }
        defaults.removeObject(forKey: "trial.total.v2"); defaults.removeObject(forKey: "trial.used.v2")
    }

    /// What the lookup found, so the developer can see what a free lookup bought (the relay sees the
    /// calls, not the outcome). Song title and artist only; see the privacy page.
    func report(song: String, title: String, cards: Int, story: Bool, failed: String?, seconds: Double) {
        guard hasPass, live else { return }
        let build = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + "(" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")"
        let prepared = request("/v1/trial/outcome", body: ["song": song, "title": title, "cards": cards, "story": story,
                                                          "failed": failed ?? "", "seconds": (seconds * 10).rounded() / 10, "build": build])
        Task { _ = try? await session.data(for: prepared); await refresh() }
    }

    nonisolated fileprivate static func errorType(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { $0["error"] as? [String: Any] }?["type"] as? String ?? ""
    }

    // MARK: Keychain (the pass survives a reinstall, like the reader's own key)

    nonisolated private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    nonisolated private static func read() -> String? {
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    nonisolated private static func store(_ value: String?) {
        SecItemDelete(query() as CFDictionary)
        guard let value else { return }
        var q = query()
        q[kSecValueData as String] = Data(value.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// The requests one lookup sends through the relay. Nothing here is tied to the main actor: the
/// research pipeline runs its searches and model calls off it.
enum TrialRelay {
    /// One lookup of one song: every request it makes carries the same pair, so the relay charges once
    /// (and a 重查 soon after rides on the same charge).
    struct Lookup: Sendable {
        let song: String
        let run: String
        let title: String
        var header: String { song + "." + run }
        init(subjectID: String, title: String, creator: String) {
            song = TrialRelay.songKey(subjectID)
            run = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
            self.title = String((title + " — " + creator).prefix(120))
        }
    }
    @TaskLocal static var lookup: Lookup?
    static func songKey(_ subjectID: String) -> String { String(DiscoveryCore.digest([subjectID]).prefix(20)) }
    static func isPass(_ credential: String) -> Bool { credential.hasPrefix(TrialAccess.tokenPrefix) }
    /// Adds the lookup's marks to a request bound for the relay; any other request is left alone.
    static func mark(_ request: inout URLRequest) {
        guard request.url?.host == TrialAccess.relayHost, let lookup else { return }
        request.setValue(lookup.header, forHTTPHeaderField: "X-Fanwai-Song")
        request.setValue(lookup.title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", forHTTPHeaderField: "X-Fanwai-Title")
    }
    /// DeepSeek's search and page tools, or the relay's copies of them for a pass.
    static func toolURL(_ tool: String, credential: String) -> URL {
        URL(string: (isPass(credential) ? TrialAccess.relay + "/ds" : "https://api.deepseek.com") + "/v1/tools/" + tool)!
    }
    /// The model client's transport for a pass: marks each request, reads what is left from each answer.
    static func transport(over base: StoryModelHTTP) -> StoryModelHTTP {
        .init { request in
            var request = request
            mark(&request)
            let (data, response) = try await base.load(request)
            if let left = response.value(forHTTPHeaderField: "X-Fanwai-Remaining").flatMap({ Int($0) }) {
                await MainActor.run { TrialAccess.shared.note(remaining: left) }
            } else if [401, 402, 429, 503].contains(response.statusCode) {
                await TrialAccess.shared.refresh()
            }
            return (data, response)
        }
    }
}
