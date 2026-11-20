import Foundation
import ImageIO
import Observation
import SwiftUI

/// The same decoded image serves the crate, hero and next page. Transport
/// cancellation never poisons a cover or removes bytes already downloaded.
@MainActor @Observable
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()
    @MainActor @Observable fileprivate final class Entry { var revision = 0 }
    @ObservationIgnored private var entries: [URL: Entry] = [:]
    private func entry(_ url: URL) -> Entry {
        if let value = entries[url] { return value }
        let value = Entry(); entries[url] = value; return value
    }
    @ObservationIgnored private let memory = NSCache<NSString, UIImage>()
    @ObservationIgnored private var tasks: [URL: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var missing: [URL: Date] = [:]
    @ObservationIgnored private var temporaryFailures: [URL: Date] = [:]
    @ObservationIgnored private let directory: URL?
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    @ObservationIgnored private let loader: Loader
    init(directory: URL? = PianwaiRuntime.cacheDirectory("DisplayImages-v1"),
         loader: @escaping Loader = { try await PianwaiRuntime.session.data(for: $0) }) {
        self.directory = directory; self.loader = loader; memory.totalCostLimit = 48 << 20
    }

    /// Synchronous consumers only consult decoded memory. Disk work belongs to
    /// load(_:), which shares one background decode for this URL.
    func image(_ url: URL) -> UIImage? {
        _ = entry(url).revision
        return memory.object(forKey: url.absoluteString as NSString)
    }
    /// An image already decoded elsewhere (tests render views with it; nothing is written to disk).
    func remember(_ image: UIImage, for url: URL) {
        memory.setObject(image, forKey: url.absoluteString as NSString, cost: Int(image.size.width * image.size.height * 4))
        entry(url).revision += 1
    }
    func permanentlyMissing(_ url: URL) -> Bool {
        _ = entry(url).revision
        return missing[url].map { Date().timeIntervalSince($0) < 1800 } ?? false
    }
    func shouldTryAlternative(_ url: URL) -> Bool {
        permanentlyMissing(url) || (temporaryFailures[url].map { Date().timeIntervalSince($0) < 60 } ?? false)
    }
    @discardableResult func load(_ url: URL) async -> UIImage? {
        if let image = image(url) { return image }
        if let task = tasks[url] { return await task.value }
        guard StoryMaterialTransport.publicURL(url), !permanentlyMissing(url) else { return nil }
        let task = Task { @MainActor [weak self] () -> UIImage? in
            guard let self else { return nil }
            defer { self.tasks[url] = nil }
            #if DEBUG && targetEnvironment(simulator)
            // Review only: hold every cover back so the waiting cover and its reveal can be seen,
            // or let every cover fail so the printed title can be seen arriving.
            if ProcessInfo.processInfo.arguments.contains("--ui-slow-covers") { try? await Task.sleep(for: .seconds(3)) }
            if ProcessInfo.processInfo.arguments.contains("--ui-missing-covers") { self.temporaryFailures[url] = Date(); return nil }
            #endif
            let file = self.file(url)
            if let image = await Task.detached(priority: .userInitiated, operation: {
                guard let file,
                      let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      Date().timeIntervalSince(date) < 30 * 86_400,
                      let data = try? Data(contentsOf: file) else { return nil as UIImage? }
                return Self.decode(data)
            }).value {
                self.memory.setObject(image, forKey: url.absoluteString as NSString, cost: 600 * 600 * 4)
                self.entry(url).revision += 1
                return image
            }
            let imageStarted = Date()
            var imageStatus = "transport-error", imageBytes = 0, decodeMS = 0.0
            defer {
                if P17Metrics.enabled {
                    let ended = Date()
                    let row = ["event": "imageRequest", "image": DiscoveryCore.digest([url.absoluteString]), "host": url.host ?? "",
                        "started": String(imageStarted.timeIntervalSince1970), "ended": String(ended.timeIntervalSince1970),
                        "bytes": String(imageBytes), "status": imageStatus, "decodeMs": String(decodeMS)]
                    Task { await P17Metrics.shared.record(row) }
                }
            }
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.setValue(SourceHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            if url.host?.hasSuffix("doubanio.com") == true { request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer") }
            do {
                let (data, response) = try await self.loader(request)
                try Task.checkCancellation()
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                imageStatus = String(code); imageBytes = data.count
                guard code == 200 else {
                    if [404, 410].contains(code) { self.missing[url] = Date(); self.entry(url).revision += 1 }
                    else { self.temporaryFailures[url] = Date() }
                    return nil
                }
                let decodeStarted = Date()
                guard data.count <= 8_000_000,
                      let image = await Task.detached(priority: .userInitiated, operation: { Self.decode(data) }).value else {
                    decodeMS = Date().timeIntervalSince(decodeStarted) * 1000; imageStatus = "decode-failed"
                    self.missing[url] = Date(); self.entry(url).revision += 1; return nil
                }
                decodeMS = Date().timeIntervalSince(decodeStarted) * 1000
                self.memory.setObject(image, forKey: url.absoluteString as NSString, cost: 600 * 600 * 4)
                self.missing[url] = nil; self.temporaryFailures[url] = nil
                self.entry(url).revision += 1
                // Publish the decoded cover before the optional disk cache is
                // encoded. The shared load task owns the write until it finishes.
                await Task.detached(priority: .utility) {
                    let measurement = EvalPerformance.begin("Artwork.encodeWrite")
                    defer { measurement?.end() }
                    if let file, let small = image.jpegData(compressionQuality: 0.9) {
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? small.write(to: file, options: .atomic)
                    }
                }.value
                return image
            } catch {
                imageStatus = (error as? URLError).map { "urlerror:" + String($0.code.rawValue) } ?? "transport-error"
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled, !Task.isCancelled {
                    self.temporaryFailures[url] = Date()
                }
                return nil
            }
        }
        tasks[url] = task
        return await task.value
    }
    private func file(_ url: URL) -> URL? { directory?.appendingPathComponent(DiscoveryCore.digest([url.absoluteString]) + ".jpg") }
    nonisolated private static func decode(_ data: Data) -> UIImage? {
        let measurement = EvalPerformance.begin("Artwork.decode", ["bytes": String(data.count)])
        defer { measurement?.end() }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600,
             kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Pin the first real image for this visit. A better source arriving later is
/// cached for the next visit instead of flashing over a cover the user saw.
/// `loading` stays true until this URL's picture is in or its load has ended; with no URL
/// there is nothing to load. The caller draws the waiting cover and the reveal
/// (CoverSheen, CoverReveal), so a cover never pops in unannounced.
struct CachedArtworkImage<Content: View>: View {
    let url: URL?
    var onFailure: () -> Void = {}
    @ViewBuilder var content: (_ image: Image?, _ loading: Bool) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var cache = ArtworkImageCache.shared
    @State private var displayed: UIImage?
    @State private var displayedURL: URL?
    /// The URL whose load ended without a picture.
    @State private var endedURL: URL?
    var body: some View {
        let image = url.flatMap { url in (displayedURL == url ? displayed : nil) ?? cache.image(url) }
        content(image.map(Image.init(uiImage:)), image == nil && url != nil && endedURL != url)
            .task(id: url) { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, url != nil, displayedURL != url || displayed == nil { Task { await load() } }
            }
    }
    private func load() async {
        guard let url else { return }
        if displayedURL != url { displayed = nil; displayedURL = url; endedURL = nil }
        if let cached = cache.image(url) { if displayed == nil { displayed = cached }; return }
        let loaded = await cache.load(url)
        guard !Task.isCancelled, displayedURL == url else { return }
        if let loaded {
            if displayed == nil { displayed = loaded }
        } else {
            endedURL = url
            if cache.shouldTryAlternative(url) { onFailure() }
        }
    }
}

/// Works whose cover a page is still looking for (LeadResearch.fillCovers runs after the cards
/// are up). Their cards keep the waiting cover until the lookup ends, instead of printing the
/// title and then swapping it for a picture.
@MainActor
final class CoverLookups {
    static let shared = CoverLookups()
    @MainActor @Observable fileprivate final class Count { var value = 0 }
    private var counts: [WorkID: Count] = [:]
    private func count(_ id: WorkID) -> Count {
        if let value = counts[id] { return value }
        let value = Count(); counts[id] = value; return value
    }
    func isLooking(_ id: WorkID) -> Bool { count(id).value > 0 }
    func begin(_ ids: some Sequence<WorkID>) { for id in ids { count(id).value += 1 } }
    func end(_ ids: some Sequence<WorkID>) { for id in ids { count(id).value = max(0, count(id).value - 1) } }
}

/// A cover still on its way: the blank stock with a slow band of light crossing it, so it
/// reads as "coming" and never as "this work has no cover". Reduce Motion: the stock breathes.
struct CoverSheen: View {
    var strength = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if reduceMotion {
                Color.white.opacity(moving ? strength * 0.32 : 0)
                    .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { moving = true } }
            } else {
                let band = max(14, w * 0.55), tall = h * 1.5 + w * 0.5
                LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                       .init(color: .white.opacity(strength), location: 0.5),
                                       .init(color: .white.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: band, height: tall)
                    .rotationEffect(.degrees(16))
                    // Starts and ends off the cover; the stretch beyond the right edge is the pause.
                    .offset(x: moving ? w + band * 0.9 : -band * 1.4, y: (h - tall) / 2)
                    .onAppear { withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) { moving = true } }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A cover's change of state (waiting → picture, waiting → printed title) is faded. In its first
/// moments on screen it is not: an answer from memory or disk should simply be there.
struct CoverReveal<Value: Equatable>: ViewModifier {
    let value: Value
    @State private var appeared: Date?
    func body(content: Content) -> some View {
        let settled = appeared.map { Date.now.timeIntervalSince($0) > 0.25 } ?? false
        content
            .animation(settled ? .easeOut(duration: 0.4) : nil, value: value)
            .onAppear { if appeared == nil { appeared = .now } }
    }
}

/// What a cover shows: still waiting, its picture, or (nothing found) its printed title.
enum CoverState: Equatable { case waiting, picture, printed }
