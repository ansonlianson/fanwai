import Foundation

/// Read only public web-tool actions. Reasoning events are ignored immediately;
/// neither their contents nor provider envelopes are persisted.
enum DiscoveryResponseStream {
    static func receive(_ request: URLRequest, session: URLSession,
                        progress: @escaping @Sendable (DiscoveryProgressEvent) async -> Void) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return (Data(), response) }
        await progress(.sent)
        let streaming = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true
        var parser = Parser(), plain = Data()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if streaming {
                let events = try parser.line(line)
                for event in events { await progress(event) }
                if parser.finished { break }
            } else {
                plain.append(contentsOf: line.utf8)
                guard plain.count <= 8_000_000 else { throw LeadResearchClient.Failure.badReply }
            }
        }
        if !streaming { return (try safeResponse(plain), response) }
        guard let data = parser.finalData else { throw LeadResearchClient.Failure.badReply }
        return (data, response)
    }

    struct Parser {
        private(set) var finalData: Data?
        private(set) var finished = false
        private var seen = Set<String>()
        mutating func line(_ line: String) throws -> [DiscoveryProgressEvent] {
            guard line.hasPrefix("data:"), line.utf8.count <= 8_000_000 else { return [] }
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { finished = true; return [] }
            guard let bytes = data.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let type = object["type"] as? String else { return [] }
            if ["response.completed", "response.incomplete"].contains(type), let response = object["response"] as? [String: Any] {
                finalData = try safeResponse(JSONSerialization.data(withJSONObject: response)); finished = true; return []
            }
            guard type == "response.output_item.done", let item = object["item"] as? [String: Any],
                  item["type"] as? String == "web_search_call", let action = item["action"] as? [String: Any] else { return [] }
            var events: [DiscoveryProgressEvent] = []
            if action["type"] as? String == "search" {
                let queries = action["queries"] as? [String] ?? (action["query"] as? String).map { [$0] } ?? []
                for query in queries where !query.isEmpty && seen.insert("search:" + query).inserted { events.append(.search(query)) }
            } else if ["open_page", "find_in_page"].contains(action["type"] as? String ?? ""),
                      let address = action["url"] as? String, let url = URL(string: address),
                      StoryMaterialTransport.publicURL(url), seen.insert("read:" + address).inserted { events.append(.read(url)) }
            return events
        }
    }

    private static func safeResponse(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LeadResearchClient.Failure.badReply }
        // The final reply adapter only needs these fields; do not retain hidden
        // reasoning items even when a provider includes them in completion.
        object = object.filter { ["id", "status", "model", "usage", "output"].contains($0.key) }
        object["output"] = (object["output"] as? [[String: Any]] ?? []).filter {
            ["message", "web_search_call"].contains($0["type"] as? String ?? "")
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
