import Foundation
import Observation

/// What one model costs: CNY per million tokens in and out, and per web search.
/// Any service can be priced (anson 2026-11-18: not DeepSeek alone): a published price the app
/// knows, or the two numbers the user enters under 模型.
struct ModelPrice: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    var search: Double = 0
    func cost(inputTokens: Int, outputTokens: Int, searches: Int) -> Double {
        (Double(inputTokens) * input + Double(outputTokens) * output) / 1_000_000 + Double(searches) * search
    }
    /// Daytime list prices the app has on file. Anything else is priced by what the user enters.
    static func published(model: String) -> ModelPrice? {
        let name = model.lowercased()
        guard name.contains("deepseek") else { return nil }
        if name.contains("flash") { return .init(input: 2, output: 8, search: 0.005) }
        if name.contains("pro") { return .init(input: 9, output: 27, search: 0.005) }
        return nil
    }
}

/// One paid lookup, as the user's own service counted it.
struct UsageEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case lookup, story, relations, deep
        /// Shown only when it was not the ordinary lookup of a page.
        var label: String? {
            switch self { case .lookup: nil; case .story: "补幕后"; case .relations: "关系图"; case .deep: "深挖" }
        }
    }
    var id = UUID()
    let date: Date
    let subjectID: String
    let title: String
    let kind: Kind
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let searches: Int
    /// CNY at the price known when it ran; nil when none was known.
    let cost: Double?
    var tokens: Int { inputTokens + outputTokens }
}

/// Every lookup the app paid for with the user's key, newest first, kept on this device.
@MainActor @Observable final class UsageLedger {
    static let shared = UsageLedger(directory: PianwaiRuntime.applicationDirectory("Usage"))
    private(set) var entries: [UsageEntry] = []
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var writing: Task<Void, Never>?
    static let limit = 500
    /// For tests: the file is written off the main thread, one snapshot after another.
    func waitForWrites() async { await writing?.value }

    init(directory: URL?) {
        file = directory?.appendingPathComponent("ledger.json")
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([UsageEntry].self, from: data)) ?? []
    }
    func record(_ entry: UsageEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        guard let file else { return }
        let snapshot = entries, previous = writing
        writing = Task.detached(priority: .utility) {
            await previous?.value
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
    func latest(for subjectID: String) -> UsageEntry? { entries.first { $0.subjectID == subjectID } }

    struct Total: Equatable {
        var cost = 0.0, count = 0, unpriced = 0
        /// 「¥0.42 · 6 次」, or the count alone when nothing in the period had a price.
        var text: String {
            guard count > 0 else { return "还没有" }
            return unpriced == count ? "\(count) 次" : String(format: "¥%.2f · %d 次", cost, count)
        }
    }
    func total(since start: Date) -> Total {
        var total = Total()
        for entry in entries where entry.date >= start {
            total.count += 1
            if let cost = entry.cost { total.cost += cost } else { total.unpriced += 1 }
        }
        return total
    }
    static func amount(_ entry: UsageEntry) -> String {
        if let cost = entry.cost { return String(format: cost < 0.1 ? "¥%.3f" : "¥%.2f", cost) }
        return entry.tokens >= 10_000 ? String(format: "%.1f 万 token", Double(entry.tokens) / 10_000) : "\(entry.tokens) token"
    }
}
