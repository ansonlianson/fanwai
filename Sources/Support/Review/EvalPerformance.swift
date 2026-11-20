import Foundation
import os
import UIKit

/// EVAL-0.5.15: opt-in observation only. No titles, URLs, keys or model text.
/// Wall durations of async functions include suspension; they are not CPU time.
enum EvalPerformance {
    static var enabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("--p17-measure") { return true }
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["PIANWAI_EVAL015_MEASURE"] == "1"
        #else
        return false
        #endif
    }
    static let log = OSLog(subsystem: "com.anson.pianwai.measurement", category: .pointsOfInterest)
    struct Interval {
        let name: StaticString
        let id: OSSignpostID
        let start: TimeInterval
        let main: Bool
        let fields: [String: String]
        func end(_ extra: [String: String] = [:]) {
            let end = Date().timeIntervalSince1970
            os_signpost(.end, log: EvalPerformance.log, name: name, signpostID: id)
            EvalPerformance.record(fields.merging(extra) { _, b in b }.merging([
                "event": "interval", "name": String(describing: name), "start": String(start),
                "end": String(end), "durationMs": String((end - start) * 1000), "main": String(main)
            ]) { _, b in b })
        }
    }
    static func begin(_ name: StaticString, _ fields: [String: String] = [:]) -> Interval? {
        guard enabled else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return .init(name: name, id: id, start: Date().timeIntervalSince1970, main: Thread.isMainThread, fields: fields)
    }
    static func event(_ name: StaticString) {
        guard enabled else { return }
        os_signpost(.event, log: log, name: name)
        record(["event": "body", "name": String(describing: name), "time": String(Date().timeIntervalSince1970)])
    }
    static func record(_ row: [String: String]) { guard enabled else { return }; Sink.shared.add(row) }
    private final class Sink: @unchecked Sendable {
        static let shared = Sink()
        private let lock = NSLock()
        private var rows: [[String: String]] = []
        private var pending = false
        private let queue = DispatchQueue(label: "pianwai.eval.measurement", qos: .utility)
        func add(_ row: [String: String]) {
            let schedule = lock.withLock { rows.append(row); if pending { return false }; pending = true; return true }
            if schedule { queue.asyncAfter(deadline: .now() + 1) { self.flush() } }
        }
        private func flush() {
            let value = lock.withLock { pending = false; return rows }
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
            var file = dir.appendingPathComponent("EVAL-perf.json")
            #if targetEnvironment(simulator)
            if let output = ProcessInfo.processInfo.environment["PIANWAI_EVAL_PERF_OUTPUT"], output.contains("/Design/review/EVAL-0.5.15/evidence/") {
                file = URL(fileURLWithPath: output)
            }
            #endif
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// Main-thread display-link gaps are a simulator fallback, not compositor hitches.
@MainActor final class EvalFrameWindow: NSObject {
    private static var active: [UUID: EvalFrameWindow] = [:]
    private let id = UUID()
    private let name: String
    private let started = Date().timeIntervalSince1970
    private var previous: CFTimeInterval?
    private var gaps: [Double] = []
    private var budgets: [Double] = []
    private var link: CADisplayLink?
    static func observe(_ name: String) {
        guard EvalPerformance.enabled else { return }
        let value = EvalFrameWindow(name: name); active[value.id] = value
        value.link = CADisplayLink(target: value, selector: #selector(tick(_:)))
        value.link?.add(to: .main, forMode: .common)
        Task { try? await Task.sleep(for: .milliseconds(1500)); value.finish() }
    }
    private init(name: String) { self.name = name }
    @objc private func tick(_ link: CADisplayLink) {
        if let previous { gaps.append((link.timestamp - previous) * 1000); budgets.append((link.targetTimestamp - link.timestamp) * 1000) }
        previous = link.timestamp
    }
    private func finish() {
        link?.invalidate(); link = nil
        let ended = Date().timeIntervalSince1970
        let missed = zip(gaps, budgets).reduce(0.0) { $0 + max(0, $1.0 - $1.1) }
        EvalPerformance.record(["event": "frameWindow", "name": name, "start": String(started), "end": String(ended),
            "samples": String(gaps.count), "maxCallbackGapMs": String(gaps.max() ?? 0),
            "missedBudgetMsPerSecond": String(missed / max(0.001, ended - started))])
        Self.active[id] = nil
    }
}


/// Source preservation for this explicit simulator evaluation. The production
/// result, prompts, acceptance rules and retry behavior are unchanged.
enum EvalResearchCapture {
    #if DEBUG && targetEnvironment(simulator)
    /// Unit tests (AhaLiveTests) keep the model's raw replies next to their results.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var directory: URL?
    static var testDirectory: URL? {
        get { lock.withLock { directory } }
        set { lock.withLock { directory = newValue } }
    }
    #endif
    static func data(_ data: Data, name: String, secret: String = "") {
        #if DEBUG && targetEnvironment(simulator)
        if let directory = testDirectory {
            let safe = secret.isEmpty ? data : Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: secret, with: "<redacted>").utf8)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? safe.write(to: directory.appendingPathComponent(name), options: .atomic)
            return
        }
        #endif
        #if targetEnvironment(simulator)
        guard EvalPerformance.enabled,
              let folder = ProcessInfo.processInfo.environment["PIANWAI_EVAL_SOURCE_OUTPUT"],
              folder.contains("/Design/review/EVAL-0.5.15/sources/") else { return }
        let safe = secret.isEmpty ? data : Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: secret, with: "<redacted>").utf8)
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? safe.write(to: directory.appendingPathComponent(name), options: .atomic)
        #endif
    }
    static func value<T: Encodable>(_ value: T, name: String) {
        #if DEBUG && targetEnvironment(simulator)
        if testDirectory != nil, let bytes = try? JSONEncoder().encode(value) { data(bytes, name: name); return }
        #endif
        guard EvalPerformance.enabled, let bytes = try? JSONEncoder().encode(value) else { return }
        data(bytes, name: name)
    }
}


struct EvalResearchSnapshot: Codable {
    let subject: LeadSubject
    let started: Date
    let finished: Date
    let state: String
    let report: LeadReport?
    let database: DatabaseDiscoveryResult?
    let skippedRelations: Bool
    let visibleCards: [Lead]
    let catalog: CatalogSnapshot
    let usage: DiscoveryUsage?
}
