import Foundation

/// Equivalent citation spellings resolve to the address actually observed by
/// the transport. Schemes, hosts and content-selecting queries remain distinct.
struct DiscoverySourceIndex: Sendable {
    private let pages: [String: String]
    init(_ observed: [String]) {
        var result: [String: String] = [:]
        for page in observed {
            // The catalog and in-app source reader share the HTTPS contract.
            // Preserve HTTP in raw evidence, but do not silently lose an edge
            // after prepare has already counted it as a confirmed discovery.
            guard URL(string: page)?.scheme == "https", let key = DiscoveryCore.sourceKey(page) else { continue }
            if result[key] == nil { result[key] = page }
        }
        pages = result
    }
    func source(_ citation: String?) -> String? {
        guard let key = DiscoveryCore.sourceKey(citation) else { return nil }
        return pages[key]
    }
}
