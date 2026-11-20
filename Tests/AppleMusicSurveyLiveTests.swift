import XCTest
import MusicKit
@testable import Pianwai

/// Opt-in simulator diagnostic. Never changes playback or records a token or
/// the SDK's raw error description. Authorization is requested only in this run.
final class AppleMusicSurveyLiveTests: XCTestCase, @unchecked Sendable {
    func testSimulatorCatalogRequest() async throws {
        guard ProcessInfo.processInfo.environment["PIANWAI_APPLE_SURVEY"] == "1" else {
            throw XCTSkip("Apple Music survey requires explicit opt-in")
        }
        #if !targetEnvironment(simulator)
        throw XCTSkip("This survey is limited to the simulator")
        #endif
        let authorization = await MusicAuthorization.request()
        var report: [String: Any] = ["bundleID": Bundle.main.bundleIdentifier ?? "",
                                      "authorization": String(describing: authorization),
                                      "request": "MusicCatalogResourceRequest<Song>(1837522108)",
                                      "timestamp": ISO8601DateFormatter().string(from: Date())]
        #if targetEnvironment(simulator)
        report["platform"] = "iOS Simulator"
        #endif
        do {
            let response = try await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: "1837522108").response()
            report["status"] = "success"
            report["songs"] = response.items.map { ["id": $0.id.rawValue, "title": $0.title] }
        } catch {
            report["status"] = "blocked"
            report["tokenError"] = (error as? MusicTokenRequestError)?.rawValue
            var chain: [[String: Any]] = [], current: NSError? = error as NSError
            for _ in 0..<6 {
                guard let item = current else { break }
                chain.append(["domain": item.domain, "code": item.code])
                current = item.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            report["errors"] = chain
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "catalog-probe.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("APPLE_CATALOG_PROBE " + String(decoding: data, as: UTF8.self))
        do {
            let url = URL(string: "https://api.music.apple.com/v1/catalog/jp/songs/1837522108")!
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            let attachment = XCTAttachment(data: response.data, uniformTypeIdentifier: "public.json")
            attachment.name = "jp-catalog-response.json"; attachment.lifetime = .keepAlways; add(attachment)
            print("APPLE_JP_CATALOG_PROBE success")
        } catch {
            let ns = error as NSError
            print("APPLE_JP_CATALOG_PROBE " + ((error as? MusicTokenRequestError)?.rawValue ?? "") + " domain=" + ns.domain + " code=" + String(ns.code))
        }
    }
}
