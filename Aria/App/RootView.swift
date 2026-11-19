import SwiftUI

struct RootView: View {
    @Environment(SonosStore.self) private var store
    @State private var showNowPlaying = false
    @Namespace private var playerTransition

    var body: some View {
        TabView {
            Tab("ホーム", systemImage: "house.fill") {
                NavigationStack { HomeView() }
                    .miniPlayerInset()
            }
            Tab("ライブラリ", systemImage: "square.stack.fill") {
                NavigationStack { LibraryView() }
                    .miniPlayerInset()
            }
            Tab("検索", systemImage: "magnifyingglass") {
                NavigationStack { SearchView() }
                    .miniPlayerInset()
            }
        }
        .modifier(MiniPlayerHost(namespace: playerTransition) { showNowPlaying = true })
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "miniPlayer", in: playerTransition))
        }
        .sonosToast()
        .background(RotationGestureInstaller())
        .task { store.start() }
    }
}

/// iOS 26 ではタブバーのアクセサリ（Apple Musicと同じ位置）に、それ以前はタブバーの上に浮かべる
private struct MiniPlayerHost: ViewModifier {
    let namespace: Namespace.ID
    let open: () -> Void

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .tabViewBottomAccessory {
                    MiniPlayer(style: .accessory, open: open)
                        .matchedTransitionSource(id: "miniPlayer", in: namespace)
                }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            MiniPlayer(style: .floating, open: open)
                .matchedTransitionSource(id: "miniPlayer", in: namespace)
                .padding(.horizontal, 10)
                .padding(.bottom, 56)
        }
    }
}

private struct MiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom) { Color.clear.frame(height: 68) }
        }
        #else
        content.safeAreaInset(edge: .bottom) { Color.clear.frame(height: 68) }
        #endif
    }
}

extension View {
    fileprivate func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
}

struct MiniPlayer: View {
    enum Style { case accessory, floating }

    @Environment(SonosStore.self) private var store
    let style: Style
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: store.track?.artworkURL, cornerRadius: style == .accessory ? 6 : 7)
                .frame(width: style == .accessory ? 32 : 44, height: style == .accessory ? 32 : 44)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.track?.title ?? "再生停止中")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { store.togglePlayPause() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            Button { store.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, style == .accessory ? 10 : 8)
        .padding(.trailing, 8)
        .frame(height: style == .accessory ? nil : 60)
        .background {
            if style == .floating {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private var subtitle: String {
        let room = store.selectedGroup?.name ?? "スピーカー未接続"
        guard let artist = store.track?.artist, !artist.isEmpty else { return room }
        return artist
    }
}
