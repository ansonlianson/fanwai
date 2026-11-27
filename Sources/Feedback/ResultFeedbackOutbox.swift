import Foundation
import Network

/// Durable, installation-scoped queue. The feedback transport has no cookies,
/// authorization header, trial token or model access; a retry uses the same UUID.
@MainActor final class ResultFeedbackOutbox {
    static let shared = ResultFeedbackOutbox()
    struct Receipt: Codable, Sendable { let id: UUID; let received: Bool }
    enum Outcome: Equatable { case sent(UUID), queued }
    enum StorageError: LocalizedError {
        case unavailable, full
        var errorDescription: String? {
            switch self { case .unavailable: "暂时没能保存反馈，请再试一次"; case .full: "还有反馈没发出，联网后再试" }
        }
    }
    typealias Sender = @Sendable (ResultFeedbackSubmission) async throws -> Receipt
    private struct State: Codable {
        var installationID = UUID()
        var queue: [ResultFeedbackSubmission] = []
    }
    private let file: URL?
    private let send: Sender
    private var state = State()
    private var readable = true
    private var draining: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var receipts: [UUID: UUID] = [:]
    private var monitor: NWPathMonitor?
    var pendingCount: Int { state.queue.count }

    init(directory: URL? = PianwaiRuntime.applicationDirectory("ResultFeedback"), sender: Sender? = nil) {
        file = directory?.appendingPathComponent("outbox.json")
        send = sender ?? Self.transmit
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do { state = try Self.decoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { readable = false } // Do not overwrite unreadable, unsent feedback.
        }
    }
    func start() {
        guard monitor == nil else { return }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data") { return }
        #endif
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor [weak self] in await self?.flush() } }
        }
        monitor.start(queue: DispatchQueue(label: "fanwai.feedback.connection"))
        self.monitor = monitor
    }
    func submit(_ draft: ResultFeedbackDraft, reasons: [ResultFeedbackReason], note: String) async throws -> Outcome {
        if let receipt = receipts[draft.id] { return .sent(receipt) }
        if !state.queue.contains(where: { $0.id == draft.id }) {
            guard state.queue.count < 50 else { throw StorageError.full }
            let prior = state
            state.queue.append(.init(id: draft.id, installationID: state.installationID,
                reasons: reasons, note: ResultFeedbackPrivacy.text(note, limit: 500), submittedAt: Date(), snapshot: draft.snapshot.boundedForDelivery()))
            do { try persist() } catch { state = prior; throw error }
        }
        await flush()
        if let receipt = receipts[draft.id] { return .sent(receipt) }
        scheduleRetry()
        return .queued
    }
    func flush() async {
        guard readable, !state.queue.isEmpty else { return }
        if let draining { await draining.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
        }
        draining = task
        await task.value
        draining = nil
    }
    private func drain() async {
        let batch = state.queue
        for submission in batch {
            do {
                let receipt = try await send(submission)
                guard receipt.received else { break }
                let previous = state
                state.queue.removeAll { $0.id == submission.id }
                do { try persist() } catch { state = previous; break }
                receipts[submission.id] = receipt.id
                if receipts.count > 100 { receipts = [submission.id: receipt.id] }
            } catch { break }
        }
    }
    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.flush()
            self?.retry = nil
        }
    }
    private func persist() throws {
        guard readable, let file else { throw StorageError.unavailable }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw StorageError.unavailable }
    }
    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    nonisolated private static func transmit(_ submission: ResultFeedbackSubmission) async throws -> Receipt {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-isolate-data") {
            if args.contains("--ui-feedback=sent") { return .init(id: submission.id, received: true) }
            throw URLError(.notConnectedToInternet)
        }
        #endif
        var request = URLRequest(url: URL(string: "https://api.fanwai.xyz/v1/feedback")!)
        request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder().encode(submission)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decoder().decode(Receipt.self, from: data)
    }
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()
}
