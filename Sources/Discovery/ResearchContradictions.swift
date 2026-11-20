import Foundation

/// Vocabulary is used only to reject explicit contradictions. A cue's presence
/// never creates a relationship, resolves passive voice, or proves an identity.
enum ResearchContradictions {
    static let nodeTypes: Set<String> = ["recording", "music_work", "movement", "release", "game", "film", "tv", "video", "book", "manga", "person", "group"]
    static let mediaWords: [String: [String]] = [
        "tv": ["tvアニメ", "テレビアニメ", "tv anime", "tv series", "television series", "电视动画", "电视剧", "連続ドラマ"],
        "film": ["劇場版", "映画", "feature film", "motion picture", "电影"],
        "game": ["ゲーム", "video game", "videogame", "游戏"],
        "manga": ["マンガ", "漫画", "コミック", "manga"],
        "book": ["小説", "novel", "小说"]
    ]
    static let sampleWords = ["サンプリング", "采样", "取样"]
    static let arrangementWords = ["編曲", "编曲", "アレンジ", "recomposed", "rearranged", "arrangement", "arranged by"]
    static let composerWords = ["作曲", "composer", "composed by", "music by"]
    static let producerWords = ["produced by", "プロデュース"]

    static func key(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    static func literal(_ value: String, in text: String) -> Bool { !value.isEmpty && key(text).contains(key(value)) }
    static func quotation(_ quote: String, in text: String) -> Bool {
        (8...240).contains(quote.count) && literal(quote, in: text)
    }
    private static func contains(_ words: [String], in text: String) -> Bool {
        words.contains { text.precomposedStringWithCompatibilityMapping.lowercased().contains($0) }
    }
    static func mediaIssue(expected: String, identityQuote: String) -> String? {
        guard mediaWords[expected] != nil else { return nil }
        let found = Set(mediaWords.compactMap { kind, words in contains(words, in: identityQuote) ? kind : nil })
        // Several real works can share a name in a single article. The local
        // identity quotation, not every word on the page, is the check's scope.
        if !found.isEmpty && !found.contains(expected) { return "mediaContradiction" }
        return nil
    }
    static func relationIssue(_ relation: String, quote: String) -> String? {
        let sample = contains(sampleWords, in: quote)
            || quote.range(of: #"\bsampl(?:e|es|ed|ing)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let arrangement = contains(arrangementWords, in: quote)
        if relation == "arrangement_of", sample, !arrangement { return "sampleIsNotArrangement" }
        if relation == "samples", arrangement, !sample { return "arrangementIsNotSample" }
        if relation == "composed_by", contains(producerWords, in: quote), !contains(composerWords, in: quote) { return "creditRoleContradiction" }
        // In particular theme/BGM/original/used are not sufficient to decide
        // created_for versus used_in, or a recording versus a musical work.
        return ResearchProofRules.contradictsRole(relation, quote: quote) ? "creditRoleContradiction" : nil
    }

    /// Shared by fresh facts and historical GPT comparison. Passing means
    /// these explicit conflicts were absent, not that the fact is certified.
    static func edgeIssue(_ relation: String, quote: String, fromName: String, fromType: String, toName: String, toType: String) -> String? {
        if let reason = relationIssue(relation, quote: quote) { return reason }
        // An adaptation may name a manga and TV series identically. One media
        // noun in such a quote cannot be assigned to both endpoints. Their
        // separate identity quotations remain the node-level evidence.
        let a = ResearchMaterials.normalized(fromName), b = ResearchMaterials.normalized(toName)
        let overlappingNames = !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a))
        if !overlappingNames {
            if literal(fromName, in: quote), let reason = mediaIssue(expected: fromType, identityQuote: quote) { return reason }
            if literal(toName, in: quote), let reason = mediaIssue(expected: toType, identityQuote: quote) { return reason }
        }
        if ["composed_by", "arranged_by", "performed_by", "featured_by", "directed_by", "authored_by"].contains(relation),
           !literal(toName, in: quote) { return "creditPersonNotQuoted" }
        return nil
    }

    static func currentScopeIssue(type: String, sourceTitle: String, quote: String) -> String? {
        // "This work" inherits the article's subject; a film article does not
        // prove adoption by a same-named TV series. Leave it unbound rather
        // than inventing the missing film node or silently retargeting it.
        guard mediaWords[type] != nil,
              quote.range(of: #"本作|该片|這部電影|这部电影|this (?:film|movie|series|game|work)"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return mediaIssue(expected: type, identityQuote: sourceTitle) == nil ? nil : "currentSubjectNotIdentified"
    }

    static func creditIssue(role: String, person: String, subject: String, quote: String, sourceTitle: String) -> String? {
        guard literal(person, in: quote), literal(role, in: quote) else { return "creditNameOrRoleNotQuoted" }
        guard literal(subject, in: quote + " " + sourceTitle) else { return "creditWorkNotIdentified" }
        let string = key(quote)
        guard let a = string.range(of: key(role)), let b = string.range(of: key(person)) else { return "creditNameOrRoleNotQuoted" }
        let distance = min(abs(string.distance(from: a.lowerBound, to: b.upperBound)), abs(string.distance(from: b.lowerBound, to: a.upperBound)))
        guard distance <= 30 else { return "creditTooFarFromName" }
        return nil
    }
    static func role(_ phrase: String) -> String? {
        if contains(composerWords, in: phrase) { return "composed_by" }
        if contains(arrangementWords, in: phrase) { return "arranged_by" }
        if contains(["演奏", "performed by", "歌唱", "歌", "vocal"], in: phrase) { return "performed_by" }
        if contains(["監督", "导演", "directed by"], in: phrase) { return "directed_by" }
        if contains(["著者", "作者", "authored by", "written by"], in: phrase) { return "authored_by" }
        return nil
    }
}
