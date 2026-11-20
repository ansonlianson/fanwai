import BackgroundTasks
import UIKit

/// A system-owned continued-processing Live Activity, not a second custom
/// widget. Ordinary ActivityKit alone would not keep a network request alive.
@MainActor
final class DiscoveryBackground {
    static let shared = DiscoveryBackground()
    private var callbacks: [String: @MainActor () -> Void] = [:]
    private var statuses: [String: @MainActor (String) -> Void] = [:]
    private var units: [String: Int64] = [:]
    private var requestID: String?
    private var continued: BGContinuedProcessingTask?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private(set) var lastSubmission = "not-requested"

    func begin(_ job: DiscoveryJob, status: @escaping @MainActor (String) -> Void,
               interrupt: @escaping @MainActor () -> Void) {
        callbacks[job.subjectID] = interrupt; units[job.subjectID] = 0
        statuses[job.subjectID] = status
        if let continued { continued.progress.totalUnitCount += 20; update(job); return }
        guard requestID == nil, UIApplication.shared.applicationState == .active else { beginGrace(); return }
        let identifier = (Bundle.main.bundleIdentifier ?? "xyz.fanwai.app") + ".discovery." + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor [weak self] in
                guard let self, self.requestID == identifier, !self.callbacks.isEmpty else { task.setTaskCompleted(success: true); return }
                self.continued = task
                self.statuses.values.forEach { $0("native-running") }
                task.progress.totalUnitCount = Int64(self.units.count * 20)
                task.progress.completedUnitCount = self.units.values.reduce(0, +)
                task.expirationHandler = { [weak self] in Task { @MainActor in self?.expire() } }
                self.endGrace()
            }
        }
        guard registered else { lastSubmission = "registration-failed"; status("grace-registration-failed"); beginGrace(); return }
        let text = Self.running(job)
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: text.title, subtitle: text.subtitle)
        request.strategy = .fail
        requestID = identifier
        // Cover the short gap before the scheduler calls the handler.
        beginGrace()
        Task { @MainActor [weak self] in
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
                if self?.requestID == identifier {
                    self?.lastSubmission = "submitted"
                    if self?.continued == nil { self?.statuses.values.forEach { $0("submitted") } }
                }
            } catch {
                guard self?.requestID == identifier else { return }
                self?.requestID = nil; self?.lastSubmission = "submission-failed"
                self?.statuses.values.forEach { $0("grace-submission-failed") }
            }
        }
    }
    func update(_ job: DiscoveryJob) {
        guard callbacks[job.subjectID] != nil else { return }
        units[job.subjectID] = Int64(job.units)
        continued?.progress.totalUnitCount = Int64(units.count * 20)
        continued?.progress.completedUnitCount = units.values.reduce(0, +)
        let text = Self.running(job)
        continued?.updateTitle(text.title, subtitle: text.subtitle)
    }

    /// The words on the system's island and Lock Screen (2026-11-16 anson chose ISLAND A): what is
    /// being looked for, then the step really taken. The system draws it with the app icon, the record.
    static func running(_ job: DiscoveryJob) -> (title: String, subtitle: String) {
        let title = "查《" + short(job.title) + "》背后的作品"
        let subtitle: String
        switch job.phase {
        case .searching:
            let searched = job.searches ?? 0, read = job.pages.count
            let steps = [searched > 0 ? "搜了 \(searched) 次" : nil, read > 0 ? "读到第 \(read) 页" : nil].compactMap { $0 }
            subtitle = steps.isEmpty ? "在找资料" : steps.joined(separator: " · ")
        case .received:
            subtitle = job.receivedCount.map { "找到 \($0) 个名字，逐个核对" } ?? "资料到了，逐个核对"
        case .checking:
            subtitle = job.lastEvent.replacingOccurrences(of: "　", with: " ")
        case .saving:
            subtitle = "快好了"
        default:
            subtitle = job.requestSent ? "在找资料" : "正在连上资料"
        }
        return (title, subtitle)
    }
    static func done(_ title: String, leads: Int, story: Bool) -> (title: String, subtitle: String) {
        let found = leads > 0 ? "\(leads) 件关联" + (story ? " · 有幕后故事" : "") : story ? "有一段幕后故事" : "这次没找到有出处的关联"
        return ("《" + short(title) + "》查好了", found)
    }
    static func short(_ title: String) -> String { title.count <= 12 ? title : String(title.prefix(11)) + "…" }
    func finish(_ id: String, title: String, summary: String, success: Bool, interrupted: Bool = false, doneTitle: String? = nil) {
        guard callbacks[id] != nil else { return }
        callbacks[id] = nil
        if success { units[id] = 20 }
        statuses[id] = nil
        continued?.progress.completedUnitCount = units.values.reduce(0, +)
        guard callbacks.isEmpty else { return }
        continued?.updateTitle(doneTitle ?? ("《" + Self.short(title) + "》" + (success ? "查好了" : interrupted ? "查到一半停了" : "没连上")), subtitle: summary)
        continued?.setTaskCompleted(success: success)
        if continued == nil, let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
        continued = nil; requestID = nil; units.removeAll(); endGrace()
    }
    private func beginGrace() {
        guard grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "片外查找") { [weak self] in
            Task { @MainActor in
                if self?.continued == nil, self?.grace != .invalid { self?.expire() }
            }
        }
    }
    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace); grace = .invalid
    }
    private func expire() {
        let pending = Array(callbacks.values)
        statuses.values.forEach { $0("interrupted") }; statuses.removeAll()
        callbacks.removeAll(); units.removeAll()
        continued?.setTaskCompleted(success: false); continued = nil
        if let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
        requestID = nil; endGrace()
        pending.forEach { $0() }
    }
}
