import Foundation

/// Apple Music形式のTTML（Better Lyrics APIが返す）を解析する。
///
/// 想定する構造:
/// ```
/// <tt><head><metadata><ttm:agent type="person" xml:id="v1"/>…</metadata></head>
///   <body dur="…"><div>
///     <p begin="…" end="…" ttm:agent="v1">
///       <span begin="…" end="…">単語</span> <span ttm:role="x-bg"><span begin="…" end="…">(コーラス)</span></span>
///     </p>
/// </div></body></tt>
/// ```
/// 単語ごとの `span` が無い場合は行単位の歌詞として扱う。
final class TTMLParser: NSObject, XMLParserDelegate {
    static func parse(_ xml: String) -> [LyricLine] {
        let normalized = bindUndeclaredPrefixes(xml.replacingOccurrences(of: "\\\"", with: "\""))
        let parser = XMLParser(data: Data(normalized.utf8))
        let delegate = TTMLParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.makeLines()
    }

    /// 宣言されていない名前空間の接頭辞（ttm: / itunes: など）を <tt> に補う。
    /// 未宣言のままだと XMLParser が途中で止まることがある。
    static func bindUndeclaredPrefixes(_ xml: String) -> String {
        guard let ttRange = xml.range(of: #"<tt\b[^>]*>"#, options: .regularExpression) else { return xml }
        let ttTag = String(xml[ttRange])
        func captures(_ pattern: String, in text: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = text as NSString
            return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) })
        }
        var declared = captures(#"xmlns:([A-Za-z][\w.-]*)\s*="#, in: ttTag)
        declared.formUnion(["xml", "xmlns"])
        let used = captures(#"</?([A-Za-z][\w.-]*):"#, in: xml)
            .union(captures(#"\s([A-Za-z][\w.-]*):[\w.-]+\s*="#, in: xml))
        let missing = used.subtracting(declared).sorted()
        guard !missing.isEmpty else { return xml }
        let additions = missing.map { " xmlns:\($0)=\"urn:aria:unbound:\($0)\"" }.joined()
        let fixedTag = ttTag.hasSuffix("/>") ? ttTag : String(ttTag.dropLast()) + additions + ">"
        return xml.replacingCharacters(in: ttRange, with: fixedTag)
    }

    /// "12.345" / "1:02.345" / "1:02:03.4" / "432.25s" / "500ms" → 秒
    static func time(_ raw: String?) -> Double? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasSuffix("ms") { return Double(value.dropLast(2)).map { $0 / 1000 } }
        if value.hasSuffix("h") { return Double(value.dropLast()).map { $0 * 3600 } }
        if value.hasSuffix("m") { return Double(value.dropLast()).map { $0 * 60 } }
        if value.hasSuffix("s") { return Double(value.dropLast()) }
        return TimeFormat.parse(value)
    }

    // MARK: State

    private struct PendingLine {
        var begin: Double
        var end: Double?
        var agent: String?
        /// itunes:key（"L12" など）。<translations> の翻訳と結び付けるのに使う
        var key: String?
        var words: [LyricWord] = []
        var background: [LyricWord] = []
        var looseText = ""
        var looseBackground = ""
    }

    private struct SpanFrame {
        var background: Bool
        var timed: Bool
        /// 時刻付きの x-bg コンテナ（中に時刻付き span が無い場合はこれ自体を1語とみなす）
        var containerTiming: (Double, Double)?
        var hasTimedChild = false
    }

    private var agentTypes: [String: String] = [:]
    private var personAgents: [String] = []
    private var inBody = false
    private var line: PendingLine?
    private var lines: [PendingLine] = []
    private var spans: [SpanFrame] = []

    /// <head> の <translations> に入っている翻訳（言語 → 行のキー → 翻訳文）
    private var translations: [String: [String: String]] = [:]
    private var translationLanguages: [String] = []
    private var inTranslations = false
    private var translationLanguage: String?
    private var translationKey: String?
    private var translationText = ""

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = XMLTreeParser.localName(elementName)
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where !key.hasPrefix("xmlns") {
            attributes[XMLTreeParser.localName(key)] = value
        }

        switch name {
        case "agent" where !inBody:
            if let id = attributes["id"] {
                let type = attributes["type"] ?? "person"
                agentTypes[id] = type
                if type == "person" || type == "character" { personAgents.append(id) }
            }
        case "translations" where !inBody:
            inTranslations = true
        case "translation" where inTranslations:
            translationLanguage = attributes["lang"] ?? "und"
            if let language = translationLanguage, !translationLanguages.contains(language) {
                translationLanguages.append(language)
            }
        case "text" where inTranslations && translationLanguage != nil:
            translationKey = attributes["for"]
            translationText = ""
        case "body":
            inBody = true
        case "p" where inBody:
            if let begin = Self.time(attributes["begin"]) {
                line = PendingLine(begin: begin, end: Self.time(attributes["end"]), agent: attributes["agent"],
                                   key: attributes["key"])
            }
        case "span" where line != nil:
            let parentBackground = spans.last?.background ?? false
            let isBackgroundContainer = attributes["role"] == "x-bg"
            let background = parentBackground || isBackgroundContainer
            let begin = Self.time(attributes["begin"])
            let end = Self.time(attributes["end"])

            if isBackgroundContainer {
                let timing: (Double, Double)? = (begin != nil && end != nil) ? (begin!, end!) : nil
                spans.append(SpanFrame(background: true, timed: false, containerTiming: timing))
            } else if let begin, let end {
                if !spans.isEmpty { spans[spans.count - 1].hasTimedChild = true }
                let word = LyricWord(start: begin, end: end, text: "")
                if background { line?.background.append(word) } else { line?.words.append(word) }
                spans.append(SpanFrame(background: background, timed: true))
            } else {
                spans.append(SpanFrame(background: background, timed: false))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if translationKey != nil {
            translationText += string
            return
        }
        guard line != nil else { return }
        guard let top = spans.last else {
            appendLoose(string, background: false)
            return
        }
        if top.timed {
            appendToLastWord(string, background: top.background)
        } else if top.background, let timing = top.containerTiming, !top.hasTimedChild,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line?.background.append(LyricWord(start: timing.0, end: timing.1, text: string))
            spans[spans.count - 1].timed = true
            spans[spans.count - 1].containerTiming = nil
        } else {
            appendLoose(string, background: top.background)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch XMLTreeParser.localName(elementName) {
        case "span":
            if line != nil, !spans.isEmpty { spans.removeLast() }
        case "p":
            if let line { lines.append(line) }
            line = nil
            spans.removeAll()
        case "body":
            inBody = false
        case "text" where translationKey != nil:
            if let language = translationLanguage, let key = translationKey {
                let text = translationText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { translations[language, default: [:]][key] = text }
            }
            translationKey = nil
        case "translation":
            translationLanguage = nil
        case "translations":
            inTranslations = false
        default:
            break
        }
    }

    /// 端末の言語の翻訳を優先し、なければ最初の言語の翻訳を使う
    private var preferredTranslations: [String: String] {
        let device = Locale.current.language.languageCode?.identifier ?? "ja"
        let language = translationLanguages.first { $0.lowercased().hasPrefix(device) } ?? translationLanguages.first
        return language.flatMap { translations[$0] } ?? [:]
    }

    // MARK: Helpers

    private func appendToLastWord(_ text: String, background: Bool) {
        if background {
            guard let index = line?.background.indices.last else { return }
            line?.background[index].text += text
        } else {
            guard let index = line?.words.indices.last else { return }
            line?.words[index].text += text
        }
    }

    /// 単語の間の空白など。直前の単語に付けて、単語単位でない歌詞は行テキストとして集める
    private func appendLoose(_ text: String, background: Bool) {
        if background {
            if line?.background.isEmpty == false { appendToLastWord(text, background: true) }
            else { line?.looseBackground += text }
        } else {
            if line?.words.isEmpty == false { appendToLastWord(text, background: false) }
            else { line?.looseText += text }
        }
    }

    private func makeLines() -> [LyricLine] {
        // 2人以上の歌い手がいるときは、2人目以降を交互に右寄せ（Apple Musicのデュエット表示）
        var order = personAgents
        for pending in lines {
            if let agent = pending.agent, agentTypes[agent] == nil, !order.contains(agent) { order.append(agent) }
        }
        let isDuet = order.count >= 2
        let translated = preferredTranslations

        let result = lines.compactMap { pending -> LyricLine? in
            var words = pending.words
            if let first = words.indices.first {
                words[first].text = String(words[first].text.drop { $0.isWhitespace })
            }
            let text = (words.isEmpty ? pending.looseText : words.map(\.text).joined())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let backgroundText = (pending.background.isEmpty ? pending.looseBackground : pending.background.map(\.text).joined())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !backgroundText.isEmpty else { return nil }

            var side = LyricLine.Side.leading
            if isDuet, let agent = pending.agent, let index = order.firstIndex(of: agent), index % 2 == 1 {
                side = .trailing
            }
            return LyricLine(id: 0, time: pending.begin, text: text, endTime: pending.end,
                             words: words, background: pending.background,
                             backgroundText: backgroundText, side: side,
                             translation: pending.key.flatMap { translated[$0] })
        }
        return LyricLine.finalize(result)
    }
}
