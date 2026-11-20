import Foundation
import StoreKit

enum PlaybackRegionOrigin: String, Codable, Sendable { case known, appStore, browsing }

enum PlaybackRegionResolver {
    struct Match: Sendable {
        let region: String
        let origin: PlaybackRegionOrigin
        let response: CatalogResponse
    }
    static func candidates(known: String?, storefront: String?, browsing: String) -> [(String, PlaybackRegionOrigin)] {
        var seen = Set<String>()
        return [(known, PlaybackRegionOrigin.known), (storefront, .appStore), (browsing, .browsing)]
            .compactMap { raw, origin in
                guard let raw, let region = country(raw), seen.insert(region).inserted else { return nil }
                return (region, origin)
            }
    }
    static func country(_ raw: String) -> String? {
        let value = raw.lowercased()
        if value.count == 2, value.utf8.allSatisfy({ (97...122).contains($0) }) { return value }
        // StoreKit returns ISO alpha-3. Foundation supplies the same ISO mapping.
        let normalized = Locale(identifier: Locale.canonicalIdentifier(from: "und_" + raw.uppercased())).region?.identifier.lowercased()
        guard let normalized, normalized.count == 2 else { return nil }
        return normalized
    }
    static func appStoreCountry() async -> String? {
        #if DEBUG && targetEnvironment(simulator)
        // Never touch a signed-in account from an isolated UI test.
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data") {
            return ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ui-storefront=") }
                .flatMap { country(String($0.dropFirst("--ui-storefront=".count))) }
        }
        #endif
        return await Storefront.current.flatMap { country($0.countryCode) }
    }
    static func resolve(number: String, known: String?, storefront: String?, browsing: String,
                        service: any CatalogFetching) async -> Match? {
        for (region, origin) in candidates(known: known, storefront: storefront, browsing: browsing).prefix(2) {
            do {
                try Task.checkCancellation()
                let response = try await service.lookup(number, country: region, entity: nil, kind: .songs)
                let exact = WorkID(rawValue: "apple:song:" + number)
                guard let exact, response.results.contains(exact),
                      response.snapshot.works.contains(where: { $0.id == exact && $0.isSong && $0.catalogID == number && $0.storeCountry == region && $0.catalogSource?.title == "iTunes" }) else { continue }
                return Match(region: region, origin: origin, response: response)
            } catch is CancellationError { return nil }
            catch { continue }
        }
        return nil
    }
}
