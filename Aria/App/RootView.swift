import SwiftUI

struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case home, library, search
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "ホーム"
            case .library: return "ライブラリ"
            case .search: return "検索"
            }
        }

        var symbol: String {
            switch self {
            case .home: return "house.fill"
            case .library: return "square.stack.fill"
            case .search: return "magnifyingglass"
            }
        }
    }

    @Environment(SonosStore.self) private var store
    @State private var section: Section = .home
    @State private var showNowPlaying = false
    @Namespace private var playerTransition
    #if DEBUG
    @State private var lyricsPreview = LyricsPreviewRequest.fromLaunchArguments
    #endif

    /// スクロールの下端に足す余白。ドック（ミニプレーヤー 60 + 間 8 + タブ 54 + 下の余白 4 = 126pt）が
    /// 最後の項目に重ならないよう、少しゆとりを持たせる
    static let dockClearance: CGFloat = 142

    var body: some View {
        ZStack(alignment: .bottom) {
            // 3つの画面は作ったまま重ねておき、切り替えても戻る位置やスクロール位置を保つ
            ZStack {
                page(.home) { HomeView() }
                page(.library) { LibraryView() }
                page(.search) { SearchView() }
            }

            Dock(section: $section, namespace: playerTransition) { showNowPlaying = true }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Theme.ink.ignoresSafeArea())
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "miniPlayer", in: playerTransition))
        }
        #if DEBUG
        .fullScreenCover(item: $lyricsPreview) { LyricsPreviewView(request: $0) }
        #endif
        .sonosToast()
        // つまみ（2本指の回転）で音量を変えている間は、指の下のボタンが押されないようにする
        .disabled(KnobState.shared.isTurning)
        .background(RotationGestureInstaller())
        .task { store.start() }
    }

    private func page<Content: View>(_ target: Section, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack { content() }
            // NavigationStack の外側に safeAreaInset を付けても、中のスクロール（ホームなど）には届かず、
            // 一番下の項目がドックの裏に隠れて触れなかった。スクロールの余白として指定すると、
            // 開いた先の画面（プレイリストなど）を含め、中のすべてのスクロールに効く
            .contentMargins(.bottom, Self.dockClearance, for: .scrollContent)
            .contentMargins(.bottom, Self.dockClearance, for: .scrollIndicators)
            .opacity(section == target ? 1 : 0)
            .allowsHitTesting(section == target)
            .accessibilityHidden(section != target)
    }
}

/// 画面下のバー。Apple Music と同じく、ミニプレイヤーを浮かべ、その下にタブを並べる
private struct Dock: View {
    @Environment(SonosStore.self) private var store
    @Binding var section: RootView.Section
    let namespace: Namespace.ID
    let open: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            MiniPlayer(open: open)
                .matchedTransitionSource(id: "miniPlayer", in: namespace)
                .glassCapsule()

            HStack(spacing: 0) {
                ForEach(RootView.Section.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 20, weight: .medium))
                                .frame(height: 24)
                            Text(item.title)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(section == item ? Theme.accent : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background {
                            if section == item {
                                Capsule().fill(.white.opacity(0.1)).padding(.horizontal, 6).padding(.vertical, 4)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .glassCapsule()
            .animation(.easeOut(duration: 0.15), value: section)
        }
        .sensoryFeedback(.selection, trigger: section)
    }
}

private extension View {
    /// すりガラスのカプセル（iOS 26 以降は Liquid Glass）
    @ViewBuilder
    func glassCapsule() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            fallbackGlass()
        }
        #else
        fallbackGlass()
        #endif
    }

    private func fallbackGlass() -> some View {
        background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

struct MiniPlayer: View {
    @Environment(SonosStore.self) private var store
    let open: () -> Void

    /// 左右にスワイプしている量（曲の表示だけを指に合わせて少し動かす）
    @State private var dragOffset: CGFloat = 0
    @State private var skipCount = 0

    /// この距離を超えて離すと曲を切り替える
    private let skipThreshold: CGFloat = 50

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
            ArtworkView(url: store.displayArtworkURL, cornerRadius: 8, seed: store.track?.title)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayTitle ?? "再生停止中")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let service = store.currentService {
                        Circle().fill(service.tint).frame(width: 5, height: 5)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            }
            .offset(x: dragOffset)
            .opacity(1 - min(abs(dragOffset) / 160, 0.5))
            Spacer(minLength: 4)
            Button { store.togglePlayPause() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(store.isPlaying ? "一時停止" : "再生")
            Button { store.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("次の曲")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 60)
        .contentShape(Capsule())
        .onTapGesture(perform: open)
        // 左にスワイプで次の曲、右にスワイプで前の曲（Apple Music のミニプレーヤーと同じ）
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                          store.track != nil else { return }
                    // 指より少し遅れて動かし、引っぱっている感じを出す
                    dragOffset = value.translation.width * 0.45
                }
                .onEnded { value in
                    let width = value.translation.width
                    if store.track != nil, abs(width) > abs(value.translation.height),
                       abs(width) > skipThreshold || abs(value.predictedEndTranslation.width) > skipThreshold * 2 {
                        if width < 0 { store.next() } else { store.previousTrack() }
                        skipCount += 1
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = 0 }
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: skipCount)
    }

    private var subtitle: String {
        let room = store.selectedGroup?.name ?? "スピーカー未接続"
        guard let artist = store.displayArtist, !artist.isEmpty else { return room }
        return artist
    }
}
