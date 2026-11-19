import SwiftUI

@main
struct AriaApp: App {
    @State private var store = SonosStore.shared
    @State private var music = AppleMusicService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(music)
                .tint(Color.appAccent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.resume()
            case .background: store.suspend()
            default: break
            }
        }
    }
}
