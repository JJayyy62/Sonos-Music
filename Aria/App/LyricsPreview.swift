#if DEBUG
import SwiftUI

/// 開発用：スピーカーなしで歌詞の画面（取得・翻訳）を確かめる。
/// 起動引数 `-AriaLyricsPreview "曲名|アーティスト|アルバム|秒数"` を付けて起動すると、その曲の歌詞を表示する。
/// リリースビルドには含まれない
struct LyricsPreviewRequest: Identifiable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    var id: String { "\(title)|\(artist)" }

    /// 歌詞を時間どおりに進める時計の起点（-AriaLyricsPreviewStart <秒> で、その位置から進める）
    @MainActor static var clockStart: Date?

    static var fromLaunchArguments: LyricsPreviewRequest? {
        guard let value = UserDefaults.standard.string(forKey: "AriaLyricsPreview") else { return nil }
        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        return LyricsPreviewRequest(title: parts[0], artist: parts[1], album: parts.count > 2 ? parts[2] : "",
                                    duration: parts.count > 3 ? Double(parts[3]) ?? 0 : 0)
    }
}

struct LyricsPreviewView: View {
    let request: LyricsPreviewRequest
    @Environment(SonosStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(request.title) — \(request.artist)")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            if request.title == "demo" {
                // 単語単位の表示を確かめるための、作り物の歌詞（実在の曲ではない）
                SyncedLyricsView(lines: Self.demoLines)
                    .padding(.horizontal, 24)
            } else {
                LyricsPanel()
                    .padding(.horizontal, 24)
            }
        }
        .background(Theme.ink.ignoresSafeArea())
        .task {
            if request.title == "demo" { LyricsPreviewRequest.clockStart = Date() }
            if UserDefaults.standard.object(forKey: "AriaLyricsPreviewStart") != nil {
                let offset = UserDefaults.standard.double(forKey: "AriaLyricsPreviewStart")
                LyricsPreviewRequest.clockStart = Date().addingTimeInterval(-offset)
            }
            store.lyrics.load(title: request.title, artist: request.artist, album: request.album,
                              duration: request.duration)
        }
    }
}
extension LyricsPreviewView {
    /// 単語ごとに時間を割り振った、確認用の歌詞
    static var demoLines: [LyricLine] {
        let phrases: [[String]] = [
            ["Testing ", "the ", "karaoke ", "sweep ", "across ", "every ", "word"],
            ["こ", "れ", "は", "歌", "詞", "の", "表", "示", "の", "テ", "ス", "ト"],
            ["Slow ", "words ", "glide ", "smoothly"],
            ["ゆっくり ", "なめらかに ", "塗られて ", "いく"],
        ]
        var lines: [LyricLine] = []
        var time = 1.0
        for (index, phrase) in phrases.enumerated() {
            let step = index >= 2 ? 1.2 : 0.45
            let start = time
            let words = phrase.map { text -> LyricWord in
                defer { time += step }
                return LyricWord(start: time, end: time + step * 0.9, text: text)
            }
            lines.append(LyricLine(id: index, time: start, text: phrase.joined(), endTime: time, words: words))
            time += 0.8
        }
        return lines
    }
}
#endif
