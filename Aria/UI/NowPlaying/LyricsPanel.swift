import SwiftUI

/// Apple Music風のリアルタイム歌詞
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
        TimelineView(.animation(minimumInterval: 0.1, paused: !store.isPlaying)) { context in
            let time = store.position(at: context.date) + store.lyrics.offset
            LyricsScroller(lines: lines, activeIndex: LyricLine.activeIndex(in: lines, at: time)) { line in
                store.seek(to: max(0, line.time - store.lyrics.offset))
            }
        }
    }
}

struct LyricsScroller: View {
    let lines: [LyricLine]
    let activeIndex: Int?
    let onTap: (LyricLine) -> Void

    @State private var userScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    private let anchor = UnitPoint(x: 0, y: 0.22)

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
                            unblurred: userScrolling)
                        .id(line.id)
                        .onTapGesture { onTap(line) }
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
                Text(line.text)
                    .font(.system(size: 30, weight: .bold))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white.opacity(isActive ? 1 : (unblurred ? 0.55 : 0.32)))
        .blur(radius: isActive || unblurred ? 0 : min(Double(distance) * 0.6, 2.4))
        .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isActive)
        .animation(.easeOut(duration: 0.25), value: unblurred)
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
