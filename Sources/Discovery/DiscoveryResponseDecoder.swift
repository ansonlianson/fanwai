import Foundation

/// Format tolerance ends at the boundary. Scalar/list credit spelling can vary
/// by provider; invalid nodes/edges do not gain identities or trusted sources.
enum DiscoveryResponseDecoder {
    static func decode(_ text: String) -> LeadResearchClient.Raw? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let nodes = object["leads"] as? [Any] else { return nil }
        let leads = nodes.compactMap { item -> LeadResearchClient.RawLead? in
            guard let d = item as? [String: Any], let name = string(d, "name"), !name.isEmpty else { return nil }
            var node = LeadResearchClient.RawLead(name: name, zh: string(d, "zh"), en: string(d, "en"), kind: string(d, "kind"),
                label: string(d, "label"), why: string(d, "why"), url: string(d, "url"), creator: credit(d, "creator"), wiki: string(d, "wiki"))
            node.ref = reference(d, "ref"); node.target_type = string(d, "target_type"); node.canonical_title = string(d, "canonical_title")
            node.composer = credit(d, "composer"); node.arranger = credit(d, "arranger"); node.performers = credit(d, "performers")
            node.work_number = string(d, "work_number"); node.movement = string(d, "movement"); node.edition = string(d, "edition")
            node.identity_url = string(d, "identity_url"); node.release_status = string(d, "release_status")
            node.release_title = string(d, "release_title")
            return node
        }
        let story: LeadResearchClient.RawStory?
        if let d = object["story"] as? [String: Any], let body = string(d, "text") {
            var value = LeadResearchClient.RawStory(text: body, subject: string(d, "subject") ?? string(d, "subject_type"), url: string(d, "url"), source: string(d, "source"))
            value.subject_ref = reference(d, "subject_ref")
            // The names the writer listed for the reader to open, and whose story a wider one is.
            // (0.5.18–0.5.25 dropped the list here, so only card names could be opened.)
            value.mentions = (d["mentions"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            value.subject_name = string(d, "subject_name")
            value.additionalSources = (d["additionalSources"] as? [[String: Any]])?.compactMap { item in
                guard let title = string(item, "title"), let url = string(item, "url"), DiscoveryCore.sourceKey(url) != nil else { return nil }
                return .init(title: title, url: url)
            }
            story = value
        } else { story = nil }
        var result = LeadResearchClient.Raw(leads: leads, story: story)
        // A missing/malformed v1 relation list is empty, never permission to invent a star.
        result.relations = (object["relations"] as? [Any] ?? []).compactMap { item in
            guard let d = item as? [String: Any], let from = reference(d, "from"), let to = reference(d, "to") else { return nil }
            return .init(from: from, to: to, relation: string(d, "relation"), label: string(d, "label"), why: string(d, "why"),
                         url: string(d, "url"), evidence_quote: string(d, "evidence_quote"))
        }
        // observedURLs and usage inside generated JSON are intentionally ignored.
        return result
    }
    private static func string(_ d: [String: Any], _ key: String) -> String? { d[key] as? String }
    private static func credit(_ d: [String: Any], _ key: String) -> String? {
        if let text = string(d, key) { return text }
        return (d[key] as? [String])?.joined(separator: "、")
    }
    private static func reference(_ d: [String: Any], _ key: String) -> String? {
        if let text = string(d, key) { return text }
        if let number = d[key] as? Int { return String(number) }
        return nil
    }
}
