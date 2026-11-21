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
            LyricsPanel()
                .padding(.horizontal, 24)
        }
        .background(Theme.ink.ignoresSafeArea())
        .task {
            store.lyrics.load(title: request.title, artist: request.artist, album: request.album,
                              duration: request.duration)
        }
    }
}
#endif
