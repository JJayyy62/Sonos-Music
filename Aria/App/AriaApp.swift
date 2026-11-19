import SwiftUI

@main
struct AriaApp: App {
    @State private var store = SonosStore.shared
    @State private var music = AppleMusicService.shared
    @State private var spotify = SpotifyService.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.styleNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(music)
                .environment(spotify)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.resume()
            case .background: store.suspend()
            default: break
            }
        }
    }

    /// ナビゲーションバーの見出しを太字にし、背景を黒にする
    private static func styleNavigationBar() {
        func rounded(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style)
            let font = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
            return font
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: rounded(.largeTitle, weight: .bold), .foregroundColor: UIColor.white]
        appearance.titleTextAttributes = [.font: rounded(.headline, weight: .bold), .foregroundColor: UIColor.white]
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundColor = UIColor(Theme.ink).withAlphaComponent(0.85)
        scrolled.shadowColor = .clear
        scrolled.largeTitleTextAttributes = appearance.largeTitleTextAttributes
        scrolled.titleTextAttributes = appearance.titleTextAttributes
        UINavigationBar.appearance().standardAppearance = scrolled
        UINavigationBar.appearance().compactAppearance = scrolled
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}
