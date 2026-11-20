import Foundation

/// The comparison baseline and the app use the same request and visible-reply
/// adapter. Provider envelopes and hidden reasoning never become saved evidence.
struct ResearchNativeAnswer: Codable, Sendable {
    let answer: ResearchWrittenAnswer
    let observedURLs: [String]
    let webToolCalls: Int
}

enum ResearchNativeResponse {
    static func body(prompt: String, model: String, deepSeek: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["model": model,
            "input": [["role": "user", "content": prompt]],
            "tools": deepSeek ? [["type": "deepseek_web_search"], ["type": "deepseek_read_url"]] : [["type": "web_search"]],
            "store": false, "stream": false, "max_output_tokens": 10000,
            "reasoning": ["effort": deepSeek ? "none" : "low"]]
        if !deepSeek { value["include"] = ["web_search_call.action.sources"] }
        return value
    }

    static func decode(_ data: Data, fallbackModel: String, seconds: Double) throws -> ResearchNativeAnswer {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = payload["output"] as? [[String: Any]] else { throw ResearchHTTP.Failure.badReply }
        let text = output.filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        var urls: [String] = []
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                if let url = object["url"] as? String, let safe = ResearchMaterials.safeURL(url) { urls.append(safe) }
                object.values.forEach(collect)
            } else if let array = value as? [Any] { array.forEach(collect) }
        }
        for item in output {
            if item["type"] as? String == "web_search_call" {
                if let action = item["action"] { collect(action) }
                if let page = item["page"] { collect(page) }
            } else if let contents = item["content"] as? [[String: Any]] {
                for content in contents { if let annotations = content["annotations"] { collect(annotations) } }
            }
        }
        let usage = payload["usage"] as? [String: Any] ?? [:]
        let counts = ResearchWriterUsage(model: payload["model"] as? String ?? fallbackModel,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            cachedInputTokens: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            reasoningTokens: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0)
        return ResearchNativeAnswer(answer: .init(text: text, completed: payload["status"] as? String == "completed",
            usage: counts, seconds: seconds), observedURLs: Array(Set(urls)).sorted(),
            webToolCalls: output.filter { $0["type"] as? String == "web_search_call" }.count)
    }
}
