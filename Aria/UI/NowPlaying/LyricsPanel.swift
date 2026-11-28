import SwiftUI

/// リアルタイム歌詞
struct LyricsPanel: View {
    @Environment(SonosStore.self) private var store

    var body: some View {
        Group {
            switch store.lyrics.state {
            case .idle, .loading:
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .synced(let lines):
                SyncedLyricsView(lines: lines)
            case .plain(let lines):
                PlainLyricsView(lines: lines, source: store.lyrics.source)
            case .instrumental:
                message("インストゥルメンタル", symbol: "music.note")
            case .notFound:
                message("この曲の歌詞は見つかりませんでした", symbol: "quote.bubble")
            case .failed:
                VStack(spacing: 12) {
                    message("歌詞を読み込めませんでした", symbol: "wifi.exclamationmark")
                    Button("再試行") { store.lyrics.retry() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.lyrics.retryTranslationIfFailed()
            keepScreenOn(store.isPlaying)
        }
        // Apple Music と同じく、歌詞を表示して再生している間は画面を暗くしない（一時停止中は通常どおり暗くなる）
        .onChange(of: store.isPlaying) { _, playing in keepScreenOn(playing) }
        .onDisappear { keepScreenOn(false) }
    }

    private func keepScreenOn(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle)
            Text(text).font(.headline)
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SyncedLyricsView: View {
    let lines: [LyricLine]
    @Environment(SonosStore.self) private var store

    var body: some View {
        // 単語単位の歌詞は滑らかに光らせるため更新頻度を上げる
        let wordSynced = lines.contains { $0.isWordSynced }
        TimelineView(.animation(minimumInterval: wordSynced ? 1.0 / 60 : 0.1, paused: !isRunning)) { context in
            let time = position(at: context.date) + store.lyrics.timingOffset
            LyricsScroller(lines: lines, activeIndex: LyricLine.activeIndex(in: lines, at: time), time: time,
                           source: store.lyrics.source,
                           translationStatus: store.lyrics.translationStatus) { line in
                store.seek(to: max(0, line.time - store.lyrics.timingOffset))
            }
        }
    }

    private var isRunning: Bool {
        #if DEBUG
        if LyricsPreviewRequest.clockStart != nil { return true }
        #endif
        return store.isPlaying
    }

    private func position(at date: Date) -> Double {
        #if DEBUG
        // 開発用の歌詞の確認画面では、スピーカーの代わりに端末の時計で進める
        if let start = LyricsPreviewRequest.clockStart { return date.timeIntervalSince(start) }
        #endif
        return store.position(at: date)
    }
}

struct LyricsScroller: View {
    let lines: [LyricLine]
    let activeIndex: Int?
    let time: Double
    let source: LyricsSource?
    var translationStatus: LyricsStore.TranslationStatus = .none
    let onTap: (LyricLine) -> Void

    @State private var userScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    private let anchor = UnitPoint(x: 0, y: 0.22)

    private var translationNote: String? {
        switch translationStatus {
        case .none: return nil
        case .translating: return "翻訳中…（Gemini）"
        case .translated(_, let model):
            return "翻訳: " + (model.map(LyricsTranslator.displayName(model:)) ?? "Gemini")
        case .failed(let reason): return "翻訳できませんでした: \(reason)"
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    Color.clear.frame(height: 24)
                    ForEach(lines) { line in
                        LyricLineView(
                            line: line,
                            isActive: line.id == activeIndex,
                            distance: abs(line.id - (activeIndex ?? 0)),
                            unblurred: userScrolling,
                            time: line.id == activeIndex ? time : nil)
                        .id(line.id)
                        .onTapGesture { onTap(line) }
                    }
                    // 歌詞の取得元と翻訳の表示は、行間を空けずにまとめて出す
                    if source != nil || translationNote != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let source {
                                Text("歌詞提供: \(source.rawValue)")
                            }
                            if let note = translationNote {
                                Text(note)
                            }
                            if case .translated = translationStatus {
                                Text("翻訳は AI によるもので、正確でない場合があります。")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 12)
                    }
                    Color.clear.frame(height: 320)
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    resumeTask?.cancel()
                    if !userScrolling { withAnimation(.easeOut(duration: 0.25)) { userScrolling = true } }
                case .idle:
                    guard userScrolling else { return }
                    resumeTask?.cancel()
                    resumeTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.3)) { userScrolling = false }
                        if let activeIndex {
                            withAnimation(.spring(response: 0.7, dampingFraction: 0.9)) {
                                proxy.scrollTo(activeIndex, anchor: anchor)
                            }
                        }
                    }
                default:
                    break
                }
            }
            .onChange(of: activeIndex) { _, newValue in
                guard let newValue, !userScrolling else { return }
                withAnimation(.spring(response: 0.65, dampingFraction: 0.88)) {
                    proxy.scrollTo(newValue, anchor: anchor)
                }
            }
            .onAppear {
                if let activeIndex { proxy.scrollTo(activeIndex, anchor: anchor) }
            }
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
    }
}

struct LyricLineView: View {
    let line: LyricLine
    let isActive: Bool
    let distance: Int
    let unblurred: Bool
    /// アクティブな行だけに渡す現在時刻（単語の光り方に使う）
    var time: Double?

    private var alignment: HorizontalAlignment { line.side == .trailing ? .trailing : .leading }
    private var frameAlignment: Alignment { line.side == .trailing ? .trailing : .leading }
    private var textAlignment: TextAlignment { line.side == .trailing ? .trailing : .leading }
    private var anchor: UnitPoint { line.side == .trailing ? .trailing : .leading }
    private var dimmed: Double { unblurred ? 0.55 : 0.32 }

    var body: some View {
        Group {
            if line.isInterlude {
                if isActive {
                    InterludeDots()
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 0)
                }
            } else {
                VStack(alignment: alignment, spacing: 6) {
                    if !line.text.isEmpty {
                        lyricView(words: line.words, plain: line.text, baseOpacity: 1,
                                  font: .system(size: 30, weight: .bold))
                    }
                    if !line.backgroundText.isEmpty {
                        lyricView(words: line.background, plain: line.backgroundText, baseOpacity: 0.75,
                                  font: .system(size: 21, weight: .semibold))
                    }
                    // Apple Music と同じく、翻訳は原文の下に小さく、少し控えめな色で出す（単語ごとには光らせない）
                    if let translation = line.translation, !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent.opacity(0.7))
                                                      : AnyShapeStyle(Color.white.opacity(dimmed * 0.8)))
                            .padding(.top, 2)
                    }
                }
                .lineSpacing(2)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .blur(radius: isActive || unblurred ? 0 : min(Double(distance) * 0.6, 2.4))
        .scaleEffect(isActive ? 1 : 0.96, anchor: anchor)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(line.side == .trailing ? .leading : .trailing, 28)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isActive)
        .animation(.easeOut(duration: 0.25), value: unblurred)
    }

    /// 歌っている行の単語単位の歌詞は、Apple Music のカラオケのように、色が文字の上を途切れなく流れていく
    /// （KaraokeRenderer で描く）。それ以外の行は普通の文字で出す
    @ViewBuilder
    private func lyricView(words: [LyricWord], plain: String, baseOpacity: Double, font: Font) -> some View {
        if isActive, let time, !words.isEmpty {
            // 文字列への埋め込み（Text("\\(a)\\(b)")）でつなぐと単語ごとの属性が消えるので、+ でつなぐ
            words.dropFirst().reduce(karaokeSegment(words[0])) { $0 + karaokeSegment($1) }
            .font(font)
            .foregroundStyle(Theme.accent.opacity(baseOpacity))
            .textRenderer(KaraokeRenderer(time: time))
        } else if isActive {
            Text(plain).font(font).foregroundStyle(Theme.accent.opacity(baseOpacity))
        } else {
            Text(plain).font(font).foregroundStyle(Color.white.opacity(dimmed * baseOpacity))
        }
    }
}

private func karaokeSegment(_ word: LyricWord) -> Text {
    Text(verbatim: word.text).customAttribute(KaraokeWord(start: word.start, end: word.end))
}

/// 単語の歌う時間（KaraokeRenderer が塗る位置を決めるのに使う）
struct KaraokeWord: TextAttribute {
    var start: Double
    var end: Double

    func progress(at time: Double) -> Double {
        guard end > start else { return time >= start ? 1 : 0 }
        return min(1, max(0, (time - start) / (end - start)))
    }
}

/// Apple Music のカラオケ風の描き方。
/// 単語ごとに、まだ歌っていない部分を薄く描き、その上に明るい色を「左から右へ進む、端のぼやけたマスク」越しに重ねる。
/// マスクの位置は時間に合わせてピクセル単位で動くので、文字単位で切り替わるより途切れなく塗りが進んで見える。
/// 歌い始めた単語は少しだけ浮き上がる
struct KaraokeRenderer: TextRenderer {
    var time: Double
    /// まだ歌っていない部分の明るさ。Apple Music では歌う前の文字もかなり明るく（歌った文字の 7 割ほど）、
    /// 塗りとの差は控えめ
    var unsungOpacity: Double = 0.6

    /// 浮き上がる高さ（pt）と、浮き上がるのにかける時間（秒）。
    /// Apple Music の画面録画をコマ送りで測ると、単語は歌われる少し前から浮き始め、約 1 秒かけて 2pt ほど上がる
    private static let liftHeight: CGFloat = 2
    private static let liftDuration: Double = 1.0
    /// 歌い始めの何秒前から浮き始めるか
    private static let liftLead: Double = 0.3

    /// 歌い始めてからの時間に対する浮き上がりの高さ（なめらかな S 字の曲線）
    static func lift(sinceStart elapsed: Double) -> CGFloat {
        let t = min(1, max(0, (elapsed + liftLead) / liftDuration))
        let eased = t * t * t * (t * (t * 6 - 15) + 10)
        return liftHeight * CGFloat(eased)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let word = run[KaraokeWord.self] else {
                    context.draw(run)
                    continue
                }
                let progress = word.progress(at: time)
                let bounds = run.typographicBounds.rect
                var wordContext = context
                // 歌い始めると、単語の長さにかかわらず一定の時間をかけて、ゆっくり加速してゆっくり止まるように浮き上がる。
                // 浮いたまま戻さない（短い単語で上下が続くと、跳ねているように見えるため）
                wordContext.translateBy(x: 0, y: -Self.lift(sinceStart: time - word.start))

                var unsung = wordContext
                unsung.opacity = unsungOpacity
                unsung.draw(run)

                guard progress > 0 else { continue }
                var sung = wordContext
                // 塗りの先端をぼかす幅（短い単語では単語の幅に合わせて狭くする）
                let feather = min(max(bounds.width * 0.35, 6), 18)
                let edge = bounds.minX - feather + (bounds.width + feather) * progress
                let maskRect = bounds.insetBy(dx: -2, dy: -bounds.height * 0.4)
                sung.clipToLayer { mask in
                    mask.fill(Path(maskRect), with: .linearGradient(
                        Gradient(stops: [.init(color: .white, location: 0), .init(color: .clear, location: 1)]),
                        startPoint: CGPoint(x: edge, y: 0),
                        endPoint: CGPoint(x: edge + feather, y: 0)))
                }
                sung.draw(run)
            }
        }
    }
}

/// 間奏中の「• • •」
struct InterludeDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = sin(t * 2.4 - Double(index) * 0.7)
                    Circle()
                        .frame(width: 12, height: 12)
                        .opacity(0.45 + 0.55 * (phase + 1) / 2)
                        .scaleEffect(0.8 + 0.25 * (phase + 1) / 2)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct PlainLyricsView: View {
    let lines: [String]
    var source: LyricsSource?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("この曲は時間同期されていない歌詞です")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 16)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 時間同期の歌詞と同じく、最後に取得元を出す
                if let source {
                    Text("歌詞提供: \(source.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 12)
                }
                Color.clear.frame(height: 120)
            }
        }
    }
}
