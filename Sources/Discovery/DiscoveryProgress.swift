import Foundation
import Observation
import SwiftUI

/// Only public tool actions and local work milestones may enter this model.
/// There is intentionally no field for model reasoning or arbitrary log text.
enum DiscoveryProgressEvent: Sendable {
    case requested, sent, search(String), read(URL), received(Int), checking(String, Int, Int), storyChecked, saving
}

struct DiscoveryJob: Codable, Sendable {
    enum Phase: String, Codable { case sending, searching, received, checking, saving, done, failed, interrupted, stopped }
    /// notAsked: only relations were looked up (a sleeve followed on the map); the page offers 查幕后.
    enum StoryResult: String, Codable { case present, notFound, rejected, notAsked }
    /// Why a lookup failed, when the reader can do something about it other than trying again.
    enum Failure: String, Codable, Sendable {
        case balance, key, model, network
        static func reason(_ error: Error) -> Self {
            func status(_ code: Int) -> Self { code == 402 ? .balance : [401, 403].contains(code) ? .key : .network }
            if let error = error as? StoryModelError {
                switch error {
                case .insufficientBalance: return .balance
                case .invalidKey: return .key
                case .unavailableModel: return .model
                case .connection: return .network
                }
            }
            if let error = error as? ResearchHTTP.Failure {
                switch error {
                case .noAccess: return .key
                case .http(let code): return status(code)
                default: return .network
                }
            }
            if let error = error as? LeadResearchClient.Failure {
                switch error {
                case .noAccess: return .key
                case .http(let code): return status(code)
                case .badReply: return .network
                }
            }
            return .network
        }
        /// One short line; `provider` is the service the reader chose (DeepSeek, …).
        func line(provider: String) -> String {
            let name = provider.isEmpty || provider == "自定义" ? "模型服务" : provider + (provider.unicodeScalars.last?.isASCII == true ? " " : "")
            switch self {
            case .balance: return name + "余额不足"
            case .key: return name + "的 API Key 用不了"
            case .model: return "选的模型用不了"
            case .network: return "没连上资料"
            }
        }
    }
    var subjectID: String
    var title: String
    var startedAt = Date()
    var phase: Phase = .sending
    var lastEvent = "在查关联和幕后"
    var userInitiated = false
    var requestSent = false
    var answerSaved = false
    var pages: [String] = []
    /// Searches really made (optional so jobs saved by older builds still decode).
    var searches: Int?
    var units = 0
    var storyResult: StoryResult?
    var failures = 0
    var failure: Failure? = nil
    var receivedCount: Int?
    var background: String? = nil
    /// A 深挖 ran on this lookup; the page then offers no further 深挖 (anson 11-18 17:30).
    var deepened: Bool? = nil
    var active: Bool { [.sending, .searching, .received, .checking, .saving].contains(phase) }
}

@MainActor @Observable
final class DiscoveryJobs {
    private(set) var values: [String: DiscoveryJob] = [:]
    @ObservationIgnored private let directory: URL?
    init(directory: URL? = PianwaiRuntime.applicationDirectory("DiscoveryJobs")) {
        self.directory = directory
        guard let directory else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), var job = try? JSONDecoder().decode(DiscoveryJob.self, from: data) else { continue }
            if job.active { job.phase = .interrupted; job.lastEvent = "查到一半停了" }
            values[job.subjectID] = job
        }
    }
    func start(_ subject: LeadSubject, userInitiated: Bool) {
        var job = DiscoveryJob(subjectID: subject.id, title: subject.title, userInitiated: userInitiated)
        job.failures = values[subject.id].flatMap { Date().timeIntervalSince($0.startedAt) < 1800 ? $0.failures : nil } ?? 0
        put(job)
    }
    func event(_ event: DiscoveryProgressEvent, id: String) {
        guard var job = values[id], job.active else { return }
        switch event {
        case .requested: job.requestSent = true
        case .sent:
            job.requestSent = true; job.units = max(job.units, 1)
        case .search(let query):
            let text = query.count <= 28 ? query : String(query.prefix(14)) + "…" + String(query.suffix(13))
            job.phase = .searching; job.lastEvent = "在搜　" + text
            job.searches = (job.searches ?? 0) + 1
            job.units = min(9, max(job.units, 1) + 1)
        case .read(let url):
            guard let host = url.host else { return }
            job.phase = .searching; job.lastEvent = "在读　" + host.replacingOccurrences(of: "www.", with: "")
            if !job.pages.contains(url.absoluteString) { job.pages.append(url.absoluteString) }
            job.units = min(9, max(job.units, 1) + 1)
        case .received(let count):
            job.phase = .received; job.answerSaved = true; job.units = max(job.units, 10)
            job.receivedCount = count
            job.lastEvent = "找到 \(count) 个名字，逐个核对"
        case .checking(let name, let index, let total):
            job.phase = .checking; job.lastEvent = "核对　\(name)（\(index)/\(total)）"
            job.units = max(job.units, total == 0 ? 18 : 10 + Int(ceil(8 * Double(index) / Double(total))))
        case .storyChecked:
            // Story is checked before metadata in the current pipeline. Its
            // milestone is counted at saving, never jumped ahead of real work.
            break
        case .saving:
            job.phase = .saving; job.units = max(job.units, 19)
        }
        put(job)
    }
    func finish(_ id: String, story: DiscoveryJob.StoryResult) {
        guard var job = values[id] else { return }
        job.phase = .done; job.storyResult = story; job.units = 20; job.failures = 0
        put(job)
    }
    func markDeepened(_ id: String) {
        guard var job = values[id], job.phase == .done else { return }
        job.deepened = true
        put(job)
    }
    func interrupt(_ id: String, stopped: Bool = false) {
        guard var job = values[id] else { return }
        job.phase = stopped ? .stopped : .interrupted; job.lastEvent = stopped ? "已停止" : "查到一半停了"
        put(job)
    }
    func fail(_ id: String, reason: DiscoveryJob.Failure = .network) {
        guard var job = values[id] else { return }
        job.phase = .failed; job.failure = reason; job.lastEvent = reason.line(provider: ""); job.failures += 1
        put(job)
    }
    func background(_ status: String, id: String) {
        guard var job = values[id] else { return }
        job.background = status; put(job)
    }
    private func put(_ job: DiscoveryJob) {
        values[job.subjectID] = job
        guard let directory, let data = try? JSONEncoder().encode(job) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(DiscoveryCore.digest([job.subjectID]) + ".json"), options: .atomic)
    }
}

struct DiscoveryProgressView: View {
    let job: DiscoveryJob
    /// One line only (the map card): the bars and the current event, no elapsed time.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: !job.active || scenePhase != .active)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(job.startedAt))
            HStack(alignment: .top, spacing: 10) {
                HStack(alignment: .bottom, spacing: 3.5) {
                    ForEach(0..<3) { i in
                        let time = (elapsed - Double(i) * 0.14).truncatingRemainder(dividingBy: 1.5)
                        let angle = reduceMotion || time < 0 || time > 0.84 ? 0 : -18 * sin(.pi * time / 0.84)
                        RoundedRectangle(cornerRadius: 1.25).fill(ArtworkPalette.tx2.opacity(0.55)).frame(width: 2.5, height: 13)
                            .rotationEffect(.degrees(angle), anchor: .bottom)
                    }
                }.frame(width: 15, height: 17)
                VStack(alignment: .leading, spacing: 5) {
                    DiscoveryProgressText(text: job.lastEvent, received: job.receivedCount, reduceMotion: reduceMotion)
                        .font(.system(size: 13)).foregroundStyle(ArtworkPalette.tx2)
                    if !compact, elapsed >= 3, !typeSize.isAccessibilitySize {
                        Text(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
                            + (job.pages.isEmpty ? "" : " · 看了 \(job.pages.count) 个页面"))
                            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(ArtworkPalette.tx3)
                    }
                }
            }.frame(height: compact ? 18 : 40, alignment: .topLeading)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("discovery-progress")
    }
}

private struct DiscoveryProgressText: View {
    let text: String
    let received: Int?
    let reduceMotion: Bool
    @State private var shown = ""
    @State private var shownAt = Date.distantPast
    @State private var receivedShown = false
    var body: some View {
        Text(shown.isEmpty ? text : shown).lineLimit(1).truncationMode(.middle)
            .contentTransition(.opacity)
            .task(id: text + ":" + String(received ?? -1)) {
                if let received, !receivedShown {
                    guard await show("找到 \(received) 个名字，逐个核对") else { return }
                    receivedShown = true
                }
                _ = await show(text)
            }
    }
    private func show(_ value: String) async -> Bool {
        guard value != shown else { return true }
        let delay = max(0, 0.8 - Date().timeIntervalSince(shownAt))
        if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return false } }
        guard !Task.isCancelled else { return false }
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.18)) { shown = value; shownAt = Date() }
        return true
    }
}
