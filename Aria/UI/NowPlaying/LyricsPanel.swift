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
                PlainLyricsView(lines: lines)
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
        TimelineView(.animation(minimumInterval: wordSynced ? 1.0 / 30 : 0.1, paused: !store.isPlaying)) { context in
            let time = store.position(at: context.date) + store.lyrics.timingOffset
            LyricsScroller(lines: lines, activeIndex: LyricLine.activeIndex(in: lines, at: time), time: time,
                           source: store.lyrics.source,
                           translationStatus: store.lyrics.translationStatus) { line in
                store.seek(to: max(0, line.time - store.lyrics.timingOffset))
            }
        }
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
                        lyricText(words: line.words, plain: line.text, baseOpacity: 1)
                            .font(.system(size: 30, weight: .bold))
                    }
                    if !line.backgroundText.isEmpty {
                        lyricText(words: line.background, plain: line.backgroundText, baseOpacity: 0.75)
                            .font(.system(size: 21, weight: .semibold))
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

    /// 単語単位の歌詞は、歌われた部分から順に明るくなる（カラオケ風）
    private func lyricText(words: [LyricWord], plain: String, baseOpacity: Double) -> Text {
        guard isActive else {
            return Text(plain).foregroundStyle(Color.white.opacity(dimmed * baseOpacity))
        }
        guard let time, !words.isEmpty else {
            return Text(plain).foregroundStyle(Theme.accent.opacity(baseOpacity))
        }
        return words.reduce(Text(verbatim: "")) { result, word in
            let progress = word.progress(at: time)
            let opacity = (0.35 + 0.65 * progress) * baseOpacity
            let segment = Text(verbatim: word.text).foregroundStyle(Theme.accent.opacity(opacity))
            return Text("\(result)\(segment)")
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
                Color.clear.frame(height: 120)
            }
        }
    }
}
