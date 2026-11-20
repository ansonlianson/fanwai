#if DEBUG
import Foundation
import FoundationModels

/// Invoked only by the explicit debug launch hook. No product UI or fallback
/// provider; the production target contains none of this probe.
@MainActor
enum EditorialModelProbe {
    static func run() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("EditorialModelProbe: Documents directory unavailable")
            return
        }
        let destination = documents.appendingPathComponent("EditorialModelProbe.json")
        do { try manager.createDirectory(at: documents, withIntermediateDirectories: true) }
        catch {
            print("EditorialModelProbe: cannot create output directory: \(error)")
            return
        }

        let model = SystemLanguageModel.default
        let locale = Locale(identifier: "zh_CN")
        let availability = model.availability
        let availabilityName: String
        let unavailableReason: String?
        switch availability {
        case .available:
            availabilityName = "available"
            unavailableReason = nil
        case .unavailable(let reason):
            availabilityName = "unavailable"
            switch reason {
            case .deviceNotEligible: unavailableReason = "deviceNotEligible"
            case .appleIntelligenceNotEnabled: unavailableReason = "appleIntelligenceNotEnabled"
            case .modelNotReady: unavailableReason = "modelNotReady"
            @unknown default: unavailableReason = String(describing: reason)
            }
        @unknown default:
            availabilityName = "unknown"
            unavailableReason = String(describing: availability)
        }
        let chineseSupported = model.supportsLocale(locale)
        let contextSize = model.contextSize
        #if targetEnvironment(simulator)
        let platform = "iOS app in simulator"
        #else
        let platform = "iOS app on device"
        #endif

        var report: [String: Any] = [
            "schemaVersion": 1,
            "probedAt": ISO8601DateFormatter().string(from: Date()),
            "platform": platform,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": "SystemLanguageModel.default",
            "availability": availabilityName,
            "availabilityRaw": String(describing: availability),
            "unavailableReason": unavailableReason as Any? ?? NSNull(),
            "locale": locale.identifier,
            "supportsLocale": chineseSupported,
            "contextSize": contextSize,
            "generation": ["status": "not_attempted"],
            "boundaries": [
                "This records only the environment named in platform; simulator availability and speed do not establish physical iPhone behavior.",
                "No settings changed, no download requested, no credentials/accounts inspected, no external AI model used.",
                "One supplied evidence pack does not establish arbitrary-work retrieval coverage or production editorial quality."
            ]
        ]
        if #available(iOS 27.0, *) { report["variant"] = String(describing: model.variant) }
        guard save(&report, to: destination, startedAt: startedAt) else { return }
        print("EditorialModelProbe: availability=\(availabilityName), reason=\(unavailableReason ?? "none"), supportsLocale(\(locale.identifier))=\(chineseSupported), contextSize=\(contextSize)")

        guard availabilityName == "available", chineseSupported else {
            report["generation"] = ["status": "not_attempted", "reason": unavailableReason ?? "unsupportedLocale"]
            _ = save(&report, to: destination, startedAt: startedAt)
            return
        }

        // Identical source pack and writing task to QA/mac-model-probe.swift.
        // These are supplied verified claims, not newly retrieved evidence.
        let sourceURL = "https://konstone.s-kon.net/modules/interview/index.php?content_id=15"
        let instructions = "你是中文音乐编辑。只整理输入材料里明确给出的事实，不补充人物动机、失败原因、听感或影响。写两句自然、简短的中文正文，不要标题，不用比喻和总结句；总长不超过100字。曲名保持原样。"
        let prompt = """
        来源：今敏官方网站访谈《2002年3月 国内の雑誌から「千年女優」に関するインタビュー》
        来源链接：\(sourceURL)
        以下是已经核对过原文的限定事实：
        1. 今敏构思《千年女优》剧本时，曾想象片尾响起平泽进《Sim City》中的《Lotus》。
        2. 《Lotus》最终没有用上。访谈只说因为若干原因，没有交代具体原因。
        3. 平泽进为电影写了《ロタティオン［Lotus2］》，作为最终片尾主题。
        请把这些事实写成两句简短中文。不要推测“若干原因”具体是什么。
        """
        let generationStartedAt = ProcessInfo.processInfo.systemUptime
        var generation: [String: Any] = [
            "status": "running",
            "sourceURL": sourceURL,
            "sourceTitle": "2002年3月 国内の雑誌から「千年女優」に関するインタビュー",
            "sourceEvidenceFile": "Research/editorial-expansion-candidates.json / sources / KON-LOTUS",
            "sourceEvidenceVerifiedAt": "2026-11-03T17:10:01.584815+00:00",
            "instructions": instructions,
            "prompt": prompt,
            "options": ["temperature": 0.2, "maximumResponseTokens": 240],
            "sourceMethod": "Previously verified source claims supplied directly; no retrieval or tool calls during generation."
        ]
        report["generation"] = generation
        guard save(&report, to: destination, startedAt: startedAt) else { return }
        do {
            try Task.checkCancellation()
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 240))
            try Task.checkCancellation()
            generation["status"] = "succeeded"
            generation["output"] = response.content
            generation["outputCharacterCount"] = response.content.count
            generation["durationSeconds"] = ProcessInfo.processInfo.systemUptime - generationStartedAt
            generation["factualReview"] = "pending human source comparison; generation success is not factual validation"
            print("EditorialModelProbe: generation=succeeded, output=\(response.content)")
        } catch {
            generation["status"] = error is CancellationError ? "cancelled" : "failed"
            generation["errorType"] = String(reflecting: type(of: error))
            generation["error"] = String(describing: error)
            generation["localizedDescription"] = error.localizedDescription
            generation["durationSeconds"] = ProcessInfo.processInfo.systemUptime - generationStartedAt
            print("EditorialModelProbe: generation=\(generation["status"]!), error=\(error)")
        }
        report["generation"] = generation
        _ = save(&report, to: destination, startedAt: startedAt)
    }

    @discardableResult
    private static func save(_ report: inout [String: Any], to destination: URL, startedAt: TimeInterval) -> Bool {
        report["totalDurationSeconds"] = ProcessInfo.processInfo.systemUptime - startedAt
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: destination, options: .atomic)
            print("EditorialModelProbe: report=\(destination.path)")
            return true
        } catch {
            print("EditorialModelProbe: cannot write report: \(error)")
            return false
        }
    }
}
#endif
