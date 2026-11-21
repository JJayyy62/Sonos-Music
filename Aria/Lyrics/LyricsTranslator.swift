import Foundation
import NaturalLanguage

/// 歌詞の翻訳（Google の Gemini API）。
///
/// - 1 曲分の歌詞をまとめて 1 回で送り、行ごとの訳を同じ順番の配列で受け取る（曲全体の文脈を踏まえて訳せる）
/// - 翻訳先の言語にもともと書かれている行は訳さない（日本語と英語が混ざった曲など）
/// - API キーは利用者が Google AI Studio で取得し、設定画面で入力する（キーチェーンに保存）
enum LyricsTranslator {
    static let enabledKey = "lyricsTranslationEnabled"
    /// 翻訳先の言語。空なら端末の設定言語
    static let languageKey = "lyricsTranslationLanguage"
    private static let apiKeyName = "gemini.apiKey"

    /// 使うモデル。新しいモデルに自動で追従する別名を使う。
    /// - Flash-Lite を先に使う：速く（1 曲数秒）、無料枠の回数も多い。歌詞の翻訳には十分な品質
    ///   （Flash は無料枠が 1 日 20 回ほどしかなく、考える処理が重くて 1 分以上かかることもある）
    /// - 使えなければ Flash を使う
    /// - どちらも廃止されていたら、API で使えるモデルの一覧を取って選ぶ
    private static let models = ["gemini-flash-lite-latest", "gemini-flash-latest"]
    private static let discoveredModelKey = "geminiDiscoveredModel"

    // MARK: 設定

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var apiKey: String? {
        get { Keychain.read(apiKeyName).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { Keychain.delete(apiKeyName) } else { Keychain.save(trimmed, for: apiKeyName) }
        }
    }

    /// 選べる翻訳先の言語（BCP 47）
    static let languages = ["ja", "en", "ko", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt", "ru",
                            "th", "vi", "id"]

    /// 端末の設定言語（選べる言語のどれか。なければ英語）
    static var deviceLanguage: String {
        let preferred = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        let code = preferred.languageCode?.identifier ?? "en"
        if code == "zh" {
            return preferred.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
        }
        return languages.contains(code) ? code : "en"
    }

    /// いま使う翻訳先の言語
    static var targetLanguage: String {
        let chosen = UserDefaults.standard.string(forKey: languageKey) ?? ""
        return languages.contains(chosen) ? chosen : deviceLanguage
    }

    /// 言語の表示名（端末の言語で）
    static func displayName(_ language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    // MARK: 翻訳

    enum TranslationError: LocalizedError {
        case invalidKey
        case quota
        case busy
        case timedOut
        case thinkingUnsupported
        case noModel
        case badResponse
        case network(Int)

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Gemini の API キーが正しくありません"
            case .quota: return "Gemini の利用回数の上限に達しました。しばらくしてからお試しください"
            case .timedOut: return "Gemini の返事が遅すぎました。次に歌詞を開いたときにもう一度試します"
            case .thinkingUnsupported: return "翻訳できませんでした"
            case .busy: return "Gemini が混み合っています。次に歌詞を開いたときにもう一度試します"
            case .noModel: return "使える Gemini のモデルが見つかりませんでした。API キーを確認してください"
            case .badResponse: return "翻訳を読み取れませんでした"
            case .network(let status): return status == 0 ? "通信できませんでした" : "Gemini からエラーが返りました（\(status)）"
            }
        }
    }

    /// 訳す必要があるか。歌詞の大半が翻訳先の言語で書かれていれば訳さない
    static func needsTranslation(_ texts: [String], to language: String) -> Bool {
        let joined = texts.joined(separator: "\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(joined)
        guard let dominant = recognizer.dominantLanguage else { return true }
        return !sameLanguage(dominant.rawValue, language)
    }

    private static func sameLanguage(_ a: String, _ b: String) -> Bool {
        // NaturalLanguage は中国語を "zh-Hans" / "zh-Hant" で返す。ほかは言語コードで比べる
        if a.hasPrefix("zh") || b.hasPrefix("zh") { return a == b }
        return a.split(separator: "-").first == b.split(separator: "-").first
    }

    /// 歌詞の各行を訳す。返す配列は `texts` と同じ長さで、訳さない行（翻訳先の言語で書かれている行など）は空文字
    static func translate(_ texts: [String], to language: String, apiKey: String) async throws -> [String] {
        var candidates = models
        if let discovered = UserDefaults.standard.string(forKey: discoveredModelKey) {
            if !candidates.contains(discovered) { candidates.append(discovered) }
        }
        #if DEBUG
        // 開発用：起動引数 -AriaGeminiModel <モデル名> で使うモデルを指定する
        if let forced = UserDefaults.standard.string(forKey: "AriaGeminiModel") { candidates = [forced] }
        #endif
        var busy = false
        var retired = false
        var overQuota = false
        for model in candidates {
            do {
                return try await translateRetrying(texts, to: language, apiKey: apiKey, model: model)
            } catch TranslationError.network(404) {
                retired = true
                continue // このモデルは使えない（廃止など）：次のモデルで試す
            } catch TranslationError.busy, TranslationError.timedOut {
                busy = true
                continue // 混んでいる・返事が遅すぎる：次のモデルで試す
            } catch TranslationError.quota {
                overQuota = true
                continue // 無料枠の回数はモデルごと：次のモデルで試す
            }
        }
        // 決めておいたモデルが廃止されていた（あるいはどれも使えない）：このキーで使えるモデルを調べ直す
        if retired || overQuota || !busy, let model = try await discoverModel(apiKey: apiKey), !candidates.contains(model) {
            UserDefaults.standard.set(model, forKey: discoveredModelKey)
            do {
                return try await translateRetrying(texts, to: language, apiKey: apiKey, model: model)
            } catch TranslationError.busy, TranslationError.timedOut {
                busy = true
            } catch TranslationError.quota {
                overQuota = true
            }
        }
        if overQuota { throw TranslationError.quota }
        throw busy ? TranslationError.busy : TranslationError.noModel
    }

    /// このキーで使えるモデルのうち、文章を生成できる Flash 系（軽くて速い）で、名前が一番新しいもの
    private static func discoverModel(apiKey: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            throw TranslationError.network(0)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 || status == 403 { throw TranslationError.invalidKey }
        guard status == 200 else { throw TranslationError.network(status) }
        struct List: Decodable {
            struct Model: Decodable { let name: String; let supportedGenerationMethods: [String]? }
            let models: [Model]?
        }
        #if DEBUG
        print("[Gemini] models (\(status)): " + ((try? JSONDecoder().decode(List.self, from: data))?.models ?? [])
            .filter { $0.name.contains("flash") }.map { "\($0.name)\($0.supportedGenerationMethods ?? [])" }
            .joined(separator: ", "))
        #endif
        // "gemini-3.8-flash-lite" のように版の番号が付いた Flash-Lite / Flash を選び、番号が一番大きいものを使う
        // （"-latest" などの別名や、preview・image などの派生版は除く）
        let versions: [(name: String, version: [Int])] = ((try? JSONDecoder().decode(List.self, from: data))?.models ?? [])
            .filter { $0.supportedGenerationMethods?.contains("generateContent") == true }
            .compactMap { model in
                let name = model.name.replacingOccurrences(of: "models/", with: "")
                guard let match = name.wholeMatch(of: /gemini-(\d+(?:\.\d+)*)-flash(-lite)?/) else { return nil }
                // Flash-Lite を Flash より優先する（版の番号の後ろに 1 を付けて比べる）
                return (name, match.1.split(separator: ".").compactMap { Int($0) } + [match.2 == nil ? 0 : 1])
            }
        return versions.max { $0.version.lexicographicallyPrecedes($1.version) }?.name
    }

    /// Gemini は混雑時に 503 などを返すことがあるので、少し待って 2 回まで試し直す
    private static func translateRetrying(_ texts: [String], to language: String, apiKey: String,
                                          model: String) async throws -> [String] {
        for delay in [1.5, 4.0] {
            do {
                return try await translate(texts, to: language, apiKey: apiKey, model: model)
            } catch TranslationError.busy {
                try await Task.sleep(for: .seconds(delay))
            }
        }
        return try await translate(texts, to: language, apiKey: apiKey, model: model)
    }

    private static func translate(_ texts: [String], to language: String, apiKey: String,
                                  model: String) async throws -> [String] {
        // モデルが受け付ける一番軽い思考の設定を、軽い順に試す
        let settings: [[String: Any]?] = model.hasPrefix("gemini-2")
            ? [["thinkingBudget": 0], nil]
            : [["thinkingLevel": "minimal"], ["thinkingLevel": "low"], nil]
        // 前に受け付けられた設定から試す（受け付けない設定で回数を無駄にしないため）
        let rememberedKey = "geminiThinking.\(model)"
        let start = min(UserDefaults.standard.integer(forKey: rememberedKey), settings.count - 1)
        for index in start..<settings.count {
            do {
                let result = try await translate(texts, to: language, apiKey: apiKey, model: model,
                                                 thinking: settings[index])
                UserDefaults.standard.set(index, forKey: rememberedKey)
                return result
            } catch TranslationError.thinkingUnsupported where index < settings.count - 1 {
                continue
            }
        }
        throw TranslationError.badResponse
    }

    /// `thinking`：モデルの「考える」処理（思考）を軽くする設定。訳すだけなので深く考える必要はなく、
    /// 既定のまま考えさせると 1 曲で 1 分以上かかってタイムアウトすることがある
    private static func translate(_ texts: [String], to language: String, apiKey: String,
                                  model: String, thinking: [String: Any]?) async throws -> [String] {
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
        let numbered = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        Translate these song lyrics into \(languageName) (\(language)).
        - Translate line by line, using the whole song as context so the meaning, tone and wordplay come through naturally.
        - Return a JSON array of exactly \(texts.count) strings, one per input line, in the same order.
        - If a line is already written in \(languageName), or is only sounds or vocalizations, return an empty string for it.
        - Return only the translation, with no line numbers, notes or romanization.

        \(numbered)
        """
        // temperature は既定のまま（Gemini 3 以降は既定より下げると同じ文を繰り返して終わらなくなることがある）。
        // 万一繰り返しても止まるように、出力の長さに上限を付ける
        var generationConfig: [String: Any] = [
            "maxOutputTokens": 8192,
            "responseMimeType": "application/json",
            "responseSchema": ["type": "ARRAY", "items": ["type": "STRING"]],
        ]
        if let thinking { generationConfig["thinkingConfig"] = thinking }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": generationConfig,
        ]
        var request = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                #if DEBUG
                print("[Gemini] \(model) thinking=\(thinking.map { "\($0)" } ?? "default") → timed out")
                #endif
                throw TranslationError.timedOut
            }
            throw TranslationError.network(0)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #if DEBUG
        print("[Gemini] \(model) thinking=\(thinking.map { "\($0)" } ?? "default") → \(status) \(status == 200 ? "" : String(decoding: data.prefix(1500), as: UTF8.self))")
        #endif
        switch status {
        case 200: break
        case 400 where String(decoding: data, as: UTF8.self).contains("API_KEY_INVALID"):
            throw TranslationError.invalidKey
        case 400 where thinking != nil && String(decoding: data, as: UTF8.self).lowercased().contains("thinking"):
            throw TranslationError.thinkingUnsupported
        case 401, 403: throw TranslationError.invalidKey
        case 429: throw TranslationError.quota
        case 500, 502, 503, 504: throw TranslationError.busy
        default: throw TranslationError.network(status)
        }

        struct Reply: Decodable {
            struct Candidate: Decodable { let content: Content? }
            struct Content: Decodable { let parts: [Part]? }
            struct Part: Decodable { let text: String? }
            let candidates: [Candidate]?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        let text = reply?.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        guard let json = text.data(using: .utf8),
              let lines = try? JSONDecoder().decode([String].self, from: json),
              lines.count == texts.count else { throw TranslationError.badResponse }
        return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
