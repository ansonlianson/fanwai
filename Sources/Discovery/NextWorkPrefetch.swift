import Foundation
import Network
import Observation

@MainActor enum PrefetchQueryBudget {
    private static var requests: [Date] = []
    static func charge() -> Bool {
        requests.removeAll { Date().timeIntervalSince($0) >= 60 }
        guard requests.count < 10 else { return false }
        requests.append(Date()); return true
    }
}

/// An explicit, non-recursive page boundary: this code only receives the
/// current crate's known IDs. It cannot discover or research grandchildren.
@MainActor @Observable
final class NextWorkPrefetch {
    static let shared = NextWorkPrefetch()
    private(set) var constrained = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let lowData = path.isConstrained
            Task { @MainActor [weak self] in self?.constrained = lowData }
        }
        monitor.start(queue: DispatchQueue(label: "com.anson.pianwai.prefetch-policy"))
    }
    static func targets(_ visible: [WorkID], context: WorkID?, excluding root: WorkID) -> [WorkID] {
        var seen: Set<WorkID> = [root]
        var result = Array(visible.prefix(6)).filter { seen.insert($0).inserted }
        if let context, seen.insert(context).inserted { result.append(context) }
        return result
    }

    /// 设置 › 提前查卡片的关联: the paid, model-backed prefetch. Off by default.
    static let paidKey = "research.prefetchNextLevel"
    /// What one card's relations-only lookup uses (measured 0.058–0.066 yuan on DeepSeek Flash, 11-18).
    static func cardCost(_ price: ModelPrice?) -> Double? { price?.cost(inputTokens: 16_000, outputTokens: 700, searches: 5) }
    func prepare(_ targets: [WorkID], root: WorkID? = nil, library: Library, research: LeadResearch) async {
        guard !constrained else { return }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        let deadline = Date().addingTimeInterval(20)
        for index in stride(from: 0, to: targets.count, by: 2) {
            guard !Task.isCancelled, !constrained, Date() < deadline else { break }
            async let first: Void = prepareOne(targets[index], library: library, research: research)
            async let second: Void = prepareOne(index + 1 < targets.count ? targets[index + 1] : nil, library: library, research: research)
            _ = await (first, second)
        }
        // One level further, from the free databases (no model, no cost): the cards' own relations.
        guard !Task.isCancelled, !constrained, let root else { return }
        await research.prefetchRelations(targets, library: library)
        guard !Task.isCancelled, !constrained, UserDefaults.standard.bool(forKey: Self.paidKey) else { return }
        await research.prefetchWithModel(targets, root: root, library: library)
    }
    private func prepareOne(_ id: WorkID?, library: Library, research: LeadResearch) async {
        guard let id, !Task.isCancelled, !constrained else { return }
        _ = await MetadataDeadline.value(seconds: 6) { @MainActor in
            let work = library.catalog.work(id), entity = SeedLibraryBridge.entity(for: id, in: library)
            let lead = research.lead(for: id.rawValue)
            async let links = WorkDestinations.resolve(entity, library: library, lead: lead, prefetch: true)
            async let versions: Void = RecordingVersionsStore.shared.load(work, library: library, prefetch: true)
            async let artwork: Void = WorkArtworkStore.shared.loadWork(work)
            // The free Wikipedia opening shown on a non-music page without a story (no model call).
            async let introduction: Void = {
                guard !entity.kind.isMusic, !work.isMusicWork, let qid = work.knowledgeID else { return }
                await WorkContextStore.shared.load(qid)
            }()
            _ = await (links, versions, artwork, introduction)
            guard !Task.isCancelled else { return false }
            let current = library.catalog.work(id)
            let image = !current.art.isEmpty ? current.art : WorkArtworkStore.shared.metadata(for: current)?.thumbnailURL
            if let image, let url = ArtworkLocation.remoteURL(URL(string: image)) { await ArtworkImageCache.shared.load(url) }
            return true
        }
    }
}
