import Foundation
import Security
import Observation
import CryptoKit

struct StoryModelPreset: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let api: StoryModelEndpoint.API
    let baseURL: String
    let models: [String]
    let modelsPath: String?
    var checkingModel: String? = nil
    let verifiedAt: String
    let source: String
    static func load(bundle: Bundle = .main) -> [Self] {
        guard let url = bundle.url(forResource: "story-model-presets", withExtension: "json"),
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return values
    }
}

struct StoryModelKeychain: Sendable {
    var service = "com.anson.pianwai.story-model.v1"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read(_ account: String) throws -> StoryModelCredential? {
        let measurement = EvalPerformance.begin("Keychain.read")
        defer { measurement?.end() }
        var q = query(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw StoryModelError.invalidKey }
        return .init(value: value)
    }
    func save(_ credential: StoryModelCredential, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: Data(credential.value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let added = query(account).merging(values) { _, new in new }
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw StoryModelError.invalidKey }
        } else if status != errSecSuccess { throw StoryModelError.invalidKey }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoryModelError.invalidKey }
    }
}

/// Immutable job snapshot: changing settings cannot mix one job's endpoint and key.
struct ResearchModelConfiguration: Sendable {
    let providerID: String
    let endpoint: StoryModelEndpoint
    let credential: StoryModelCredential
    let http: StoryModelHTTP
    /// Research saved while the developer's own service was a built-in choice stays readable
    /// now that the same service is an ordinary 自定义 entry.
    var legacyNamespace: String? = nil
    /// The name the user sees for this service, and what its model costs (when known).
    var providerName = ""
    var price: ModelPrice? = nil
    var namespace: String {
        legacyNamespace ?? (providerID == "internal" ? "gpt-" + endpoint.model
            : "byok-" + DiscoveryCore.digest([providerID, endpoint.api.rawValue, endpoint.baseURL, endpoint.model]))
    }
    /// DeepSeek itself, or 番外's relay standing in front of it for a 体验码 pass: the same search tool and chat interface.
    var isDeepSeek: Bool { URL(string: endpoint.baseURL)?.host == "api.deepseek.com" || isTrial }
    var isTrial: Bool { providerID == "trial" }
    func client(checking: Bool = false) -> any StoryModelClient {
        switch endpoint.api {
        case .responses: OpenAIResponsesClient(endpoint: endpoint, credential: credential, http: http)
        case .anthropic: AnthropicClient(endpoint: endpoint, credential: credential, http: http)
        case .openAI: OpenAICompatibleClient(allowsThinking: checking, endpoint: endpoint, credential: credential, http: http)
        }
    }
}

@MainActor @Observable final class StoryModelSettings {
    static let shared = runtime()
    static func runtime() -> StoryModelSettings {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-story-model-fixture") {
            let keychain = StoryModelKeychain(service: "com.anson.pianwai.story-model.ui-fixture")
            if arguments.contains("--ui-reset") {
                try? keychain.remove("deepseek")
                // Every account of the review keychain (自定义 keys are stored by address).
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychain.service] as CFDictionary)
            }
            let settings = StoryModelSettings(defaults: RelationTrailStore().defaults, keychain: keychain, pass: .shared, http: .init { request in
                let ok = { (body: String) in (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
                // A real service takes a few seconds; the review shows the 正在连接 state.
                if arguments.contains("--ui-slow-model") { try? await Task.sleep(for: .seconds(2)) }
                // Onboarding review (ONBOARDING, 2026-11-18): a key the service refuses, and an empty account.
                if arguments.contains("--ui-key-refused") {
                    return (Data(#"{"error":{"message":"Authentication Fails","type":"authentication_error"}}"#.utf8),
                            HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
                if request.url?.path.hasSuffix("/user/balance") == true {
                    let amount = arguments.contains("--ui-balance-empty") ? "0.00" : "10.00"
                    return ok(#"{"is_available":\#(amount != "0.00"),"balance_infos":[{"currency":"CNY","total_balance":"\#(amount)","granted_balance":"0.00","topped_up_balance":"\#(amount)"}]}"#)
                }
                if arguments.contains("--ui-balance-empty"), request.httpMethod == "POST" {
                    return (Data(#"{"error":{"message":"Insufficient Balance","type":"unknown_error"}}"#.utf8),
                            HTTPURLResponse(url: request.url!, statusCode: 402, httpVersion: nil, headerFields: nil)!)
                }
                if request.url?.path.hasSuffix("/tools/search") == true {
                    let body = arguments.contains("--ui-story-search-empty") ? #"{"results":[]}"#
                        : #"{"results":[{"url":"https://musicbrainz.org/","content":""}]}"#
                    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let body = request.httpMethod == "POST"
                    ? #"{"model":"fixture","choices":[{"message":{"content":"OK"}}]}"#
                    : #"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            // Review: a page that has a model set up (the lookup itself is replayed, never sent).
            if arguments.contains("--ui-story-model-ready") {
                settings.selectProvider("deepseek"); settings.selectModel("deepseek-flash"); settings.saveKey("fixture-key")
            }
            return settings
        }
        if arguments.contains("--ui-isolate-data") {
            let live = arguments.contains("--ui-internal-story-live") || arguments.contains("--ui-leads-live") || arguments.contains("--ui-internal-model-preview")
            return StoryModelSettings(defaults: RelationTrailStore().defaults,
                keychain: .init(service: "com.anson.pianwai.story-model.isolated"), pass: .shared,
                internalAccess: live ? InternalStoryModel.access() : nil)
        }
        #endif
        let access = InternalStoryModel.access()
        let settings = StoryModelSettings(pass: .shared, internalAccess: access)
        if access?.deepseekCredential != nil, settings.preferences.internalDeepSeekDisabled != true {
            let migrationKey = "redesign.storyModel.deepseekDefaulted.v1"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                settings.selectProvider("deepseek")
                settings.selectModel("deepseek-flash")
            }
        }
        return settings
    }
    struct Preferences: Codable, Equatable {
        var providerID: String = ""
        var customAddress = ""
        var models: [String: String] = [:]
        var customAPI: StoryModelEndpoint.API? = nil
        var internalDeepSeekDisabled: Bool? = nil
        /// The developer removed the key of the seeded 自定义 entry: the build's own key is not used either.
        var internalCustomDisabled: Bool? = nil
        /// Prices the user entered, by provider and model (「deepseek|deepseek-flash」).
        var prices: [String: ModelPrice]? = nil
    }
    let presets: [StoryModelPreset]
    private(set) var preferences: Preferences
    private(set) var availableModels: [String] = []
    private(set) var hasRemoteModelList = false
    /// The list is being asked of the service the key belongs to.
    private(set) var modelsLoading = false
    private(set) var maskedKey = ""
    private(set) var connectionResult: String?
    private(set) var testing = false
    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: StoryModelKeychain
    @ObservationIgnored private let http: StoryModelHTTP
    @ObservationIgnored private let internalAccess: InternalStoryModel.Access?
    /// The 体验码 pass, used while the reader has no service of their own.
    @ObservationIgnored private let pass: TrialAccess
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    private static let key = "redesign.storyModel.preferences.v1"

    init(defaults: UserDefaults = .standard, keychain: StoryModelKeychain = .init(), pass: TrialAccess? = nil,
         presets: [StoryModelPreset] = StoryModelPreset.load(), http: StoryModelHTTP = .init(),
         internalAccess: InternalStoryModel.Access? = nil) {
        self.defaults = defaults; self.keychain = keychain; self.http = http; self.internalAccess = internalAccess
        // Only the app's own settings object uses the reader's pass (see runtime()).
        self.pass = pass ?? .none
        // The app has no service of its own (anson 2026-11-18): every provider is one the user configures.
        // Only services the app can search the web with are offered (anson 2026-11-18 13:00): without a
        // search a lookup finds no story at all.
        self.presets = presets.filter { Self.searchCapable.contains($0.id) }
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
        preferences = stored ?? Preferences(providerID: internalAccess == nil ? "" : "custom")
        // The removed built-in choice becomes the 自定义 entry seeded below.
        if preferences.providerID == "internal" { preferences.providerID = internalAccess == nil ? "" : "custom" }
        if !preferences.providerID.isEmpty, !self.presets.contains(where: { $0.id == preferences.providerID }) { preferences.providerID = "" }
        seedInternalAccess()
        if preferences != stored, let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.key) }
        refreshLocal()
    }
    /// A developer's internal build carries that developer's own service address in a private
    /// bundle file (never in source, never in a build that is handed out). It is written once into
    /// the 自定义 provider, where a user's own entry lives, so the app lists no provider of its
    /// own. A slot the user already filled is left alone. The keys themselves stay in the bundle
    /// and are never copied to the keychain (U17); removing the key turns the bundled one off.
    private func seedInternalAccess() {
        guard let access = internalAccess, !defaults.bool(forKey: Self.seedKey) else { return }
        defaults.set(true, forKey: Self.seedKey)
        guard preferences.customAddress.isEmpty else { return }
        preferences.customAddress = access.preset.baseURL
        preferences.customAPI = access.preset.api
        if let model = access.preset.models.first { preferences.models["custom"] = model }
    }
    private static let seedKey = "redesign.storyModel.internalSeed.v1"
    private static func customAccount(_ address: String) -> String {
        "custom/" + SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Where lookups are filed. A pass that has run out still shows what it found.
    var researchNamespace: String {
        configuration()?.namespace ?? (pass.hasPass ? passNamespace : nil) ?? "gpt-" + (internalAccess?.preset.models.first ?? "")
    }
    private var passModel: String { pass.defaultModels["deepseek"] ?? "deepseek-flash" }
    /// The same place the reader's own DeepSeek key files that model's lookups.
    private var passNamespace: String? {
        presets.first { $0.id == "deepseek" }.map { "byok-" + DiscoveryCore.digest([$0.id, $0.api.rawValue, $0.baseURL, passModel]) }
    }
    var preset: StoryModelPreset? { presets.first { $0.id == preferences.providerID } }
    /// The model a service starts on: what 番外's own configuration page names for it now (services rename
    /// their models), then what was known when this build was made.
    private var fallbackModels: [String] {
        guard preferences.providerID != "custom" else { return [] }
        return (pass.defaultModels[preferences.providerID].map { [$0] } ?? []) + (preset?.models ?? [])
    }
    var model: String { preferences.models[preferences.providerID] ?? fallbackModels.first ?? "" }
    /// Typed by hand when the service gave no list, or (自定义) only repeated the model already set.
    var usesManualModel: Bool { !hasRemoteModelList || (preferences.providerID == "custom" && availableModels.count <= 1) }
    var hasKey: Bool { !maskedKey.isEmpty }
    /// DeepSeek searches with its own search tool; OpenAI and 自定义 speak the Responses
    /// interface, whose web search runs inside the call. Other services need their own adapter.
    static let searchCapable: Set<String> = ["deepseek", "openai", "custom"]
    /// The user never picks an interface: 自定义 pointing at DeepSeek uses its chat interface and
    /// search tool; any other address uses Responses, the one with web search built in.
    static func customAPI(address: String) -> StoryModelEndpoint.API {
        URL(string: address)?.host == "api.deepseek.com" ? .openAI : .responses
    }
    var endpoint: StoryModelEndpoint? {
        guard let preset else { return nil }
        return .init(api: preset.id == "custom" ? Self.customAPI(address: preferences.customAddress) : preset.api,
            baseURL: preset.id == "custom" ? preferences.customAddress : preset.baseURL, model: model, modelsPath: preset.modelsPath)
    }
    private var account: String {
        guard preferences.providerID == "custom" else { return preferences.providerID }
        return Self.customAccount(preferences.customAddress)
    }
    /// Whether 自定义 currently points at the address an internal build was seeded with.
    private var usesSeededAddress: Bool {
        preferences.providerID == "custom" && internalAccess != nil && preferences.customAddress == internalAccess?.preset.baseURL
    }
    private var credential: StoryModelCredential? {
        if let saved = try? keychain.read(account) { return saved }
        if usesSeededAddress, preferences.internalCustomDisabled != true { return internalAccess?.credential }
        if preferences.providerID == "deepseek", preferences.internalDeepSeekDisabled != true { return internalAccess?.deepseekCredential }
        return nil
    }
    /// The reader's own service when one is set up; else the 体验码 pass while it has lookups left.
    func configuration(checking: Bool = false) -> ResearchModelConfiguration? {
        own(checking: checking) ?? (checking ? nil : trial())
    }
    /// A pass goes through the relay with DeepSeek's small model. What it finds is filed where the reader's
    /// own DeepSeek key would file it, so nothing is looked up (and paid for) twice after they add one.
    private func trial() -> ResearchModelConfiguration? {
        guard pass.usable, let token = pass.token else { return nil }
        return .init(providerID: "trial",
            endpoint: .init(api: .openAI, baseURL: TrialAccess.relay + "/ds", model: passModel, modelsPath: nil),
            credential: .init(value: token), http: TrialRelay.transport(over: http),
            legacyNamespace: passNamespace, providerName: "体验码", price: nil)
    }
    private func own(checking: Bool) -> ResearchModelConfiguration? {
        guard let endpoint, !endpoint.model.isEmpty, (try? endpoint.url("")) != nil, let credential else { return nil }
        let legacy = usesSeededAddress && endpoint.api == .responses
        return .init(providerID: preferences.providerID,
            endpoint: .init(api: endpoint.api, baseURL: endpoint.baseURL,
                model: checking ? preset?.checkingModel ?? endpoint.model : endpoint.model, modelsPath: endpoint.modelsPath),
            credential: credential, http: http, legacyNamespace: legacy ? "gpt-" + endpoint.model : nil,
            providerName: preset?.name ?? "", price: price)
    }
    private var priceKey: String { preferences.providerID + "|" + model }
    /// What the user entered for the chosen model, if anything.
    var enteredPrice: ModelPrice? { preferences.prices?[priceKey] }
    /// The price lookups are estimated with: the user's own numbers first, else a published one.
    var price: ModelPrice? { enteredPrice ?? ModelPrice.published(model: model) }
    /// Both numbers are needed for an estimate; clearing either removes the entry.
    func setPrice(input: Double?, output: Double?) {
        guard !preferences.providerID.isEmpty, !model.isEmpty else { return }
        // Read the key first: it is derived from `preferences`, which is about to be changed.
        let key = priceKey
        var all = preferences.prices ?? [:]
        if let input, let output, input >= 0, output >= 0 {
            all[key] = .init(input: input, output: output, search: ModelPrice.published(model: model)?.search ?? 0)
        } else {
            all.removeValue(forKey: key)
        }
        preferences.prices = all.isEmpty ? nil : all
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.key) }
        priceRevision += 1
    }
    /// Price edits must not cancel a connection test or a model-list request (`revision` does).
    private(set) var priceRevision = 0
    func selectProvider(_ id: String) {
        guard id.isEmpty || presets.contains(where: { $0.id == id }) else { return }
        modelTask?.cancel(); preferences.providerID = id; changed(); refreshLocal(); refreshModels()
    }
    func setAddress(_ value: String) {
        preferences.customAddress = value.trimmingCharacters(in: .whitespacesAndNewlines); changed(); refreshLocal()
    }
    func selectModel(_ value: String) { preferences.models[preferences.providerID] = value; changed() }
    func saveKey(_ value: String) {
        guard !preferences.providerID.isEmpty else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try keychain.save(.init(value: value), account: account); changed(); refreshLocal(); refreshModels() }
        catch { connectionResult = StoryModelError.invalidKey.rawValue }
    }
    func removeKey() {
        guard !preferences.providerID.isEmpty else { return }
        modelTask?.cancel()
        do {
            try keychain.remove(account)
            if preferences.providerID == "deepseek" { preferences.internalDeepSeekDisabled = true }
            if usesSeededAddress { preferences.internalCustomDisabled = true }
            changed(); refreshLocal()
        }
        catch { connectionResult = StoryModelError.invalidKey.rawValue }
    }
    func client(checking: Bool = false) -> (any StoryModelClient)? { configuration(checking: checking)?.client(checking: checking) }
    /// A service lists every model it has: speech, pictures, embeddings and so on. Only models that
    /// can take a web search in the call are offered. DeepSeek's search is a separate tool, so any
    /// of its chat models works.
    static func searchable(model: String, api: StoryModelEndpoint.API) -> Bool {
        let name = model.lowercased()
        guard api == .responses else { return true }
        let excluded = #"embed|tts|whisper|dall-e|image|audio|realtime|transcribe|moderation|search-preview|instruct|babbage|davinci|gpt-3\.5|computer-use|codex|^o1|sora|^gpt-4$|^gpt-4-"#
        return name.range(of: excluded, options: .regularExpression) == nil
    }
    /// The models offered are the ones the service itself lists once the key is in (anson
    /// 2026-11-18: no ready-made list). The preset only says which one to start on.
    func refreshModels() {
        modelTask?.cancel()
        guard let configuration = configuration() else { modelsLoading = false; return }
        let version = revision
        modelsLoading = true
        modelTask = Task {
            let listed = (try? await configuration.client().models()) ?? []
            let values = listed.filter { Self.searchable(model: $0, api: configuration.endpoint.api) }
            guard !Task.isCancelled, version == revision else { return }
            modelsLoading = false
            hasRemoteModelList = !values.isEmpty
            guard !values.isEmpty else { availableModels = model.isEmpty ? [] : [model]; return }
            availableModels = values
            if !values.contains(model) {
                preferences.models[preferences.providerID] = fallbackModels.first(where: values.contains) ?? values.first
                changed(); modelsLoading = false
            }
        }
    }
    func testConnection() async {
        guard !testing else { return }
        guard let configuration = configuration() else {
            connectionResult = hasKey ? StoryModelError.unavailableModel.rawValue : StoryModelError.invalidKey.rawValue; return
        }
        let version = revision
        testing = true; connectionResult = nil; probeResult = nil; connectionError = nil
        defer { testing = false }
        do {
            let result = try await ResearchCapabilityProbe.check(configuration)
            if version == revision { connectionResult = result.message; probeResult = result }
        } catch {
            let failure = (error as? StoryModelError) ?? .connection
            if version == revision { connectionResult = failure.rawValue; connectionError = failure }
        }
    }
    /// What the last 测试连接 found, for the first-run check (OnboardingKeyCheck).
    private(set) var probeResult: ResearchCapabilityProbe.Result?
    private(set) var connectionError: StoryModelError?
    /// DeepSeek's own account balance (GET /user/balance), shown once after the key is in.
    /// Other services publish no balance the app can read; nil then.
    func deepSeekBalance() async -> Double? {
        guard let configuration = configuration(), configuration.isDeepSeek else { return nil }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!, timeoutInterval: 15)
        request.setValue("Bearer " + configuration.credential.value, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Reply: Decodable {
            struct Info: Decodable { let currency: String; let total_balance: String }
            let balance_infos: [Info]
        }
        guard let data = try? await http.send(request),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return reply.balance_infos.first { $0.currency == "CNY" }.flatMap { Double($0.total_balance) }
    }
    private func refreshLocal() {
        hasRemoteModelList = false; modelsLoading = false
        availableModels = model.isEmpty ? [] : [model]
        maskedKey = credential == nil ? "" : "••••••••"
    }
    private func changed() {
        revision += 1; connectionResult = nil; probeResult = nil; connectionError = nil
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.key) }
    }
}
