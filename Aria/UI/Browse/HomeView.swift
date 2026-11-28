import SwiftUI

struct HomeView: View {
    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    @Environment(SpotifyService.self) private var spotify
    @State private var appleShelves: [AppleMusicShelf] = []
    @State private var spotifyShelves: [CatalogShelf] = []
    @State private var appleLibraryShelves: [CatalogShelf] = []
    @State private var showSettings = false
    @State private var showRooms = false
    @AppStorage("homeServiceFilter") private var filterRaw = ""

    private var filter: StreamingService? { StreamingService(rawValue: filterRaw) }
    private var filterBinding: Binding<StreamingService?> {
        Binding(get: { filter }, set: { filterRaw = $0?.rawValue ?? "" })
    }

    private func shows(_ service: StreamingService) -> Bool { filter == nil || filter == service }

    /// まだつないでいないサービス（「すべて」のときに案内カードを出す）
    private var unconnected: [StreamingService] {
        var list: [StreamingService] = []
        if !music.isAuthorized { list.append(.appleMusic) }
        if !spotify.isConnected { list.append(.spotify) }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 18) {
                    HomeHeader(showRooms: $showRooms, showSettings: $showSettings)
                    if !store.groups.isEmpty {
                        ChipBar.services(selection: filterBinding)
                    }
                }

                if store.groups.isEmpty {
                    ConnectView()
                        .padding(.top, 12)
                } else {
                    shelves
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.ink.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await reload() }
        .task(id: store.selectedGroup?.coordinator.uuid) {
            await store.loadFavorites()
        }
        .task(id: music.isAuthorized) {
            await loadApple()
        }
        .task(id: spotify.isConnected) {
            spotifyShelves = await spotify.homeShelves()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showRooms) {
            RoomPickerView().presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var shelves: some View {
        let favorites = store.favorites(for: filter)
        let appleVisible = shows(.appleMusic) ? appleShelves : []
        let spotifyVisible = shows(.spotify) ? spotifyShelves : []
        let appleLibraryVisible = shows(.appleMusic) ? appleLibraryShelves : []
        let favoriteOffset = favorites.isEmpty ? 0 : 1

        if !favorites.isEmpty {
            Shelf(index: 1, label: "Sonos Favorites", title: "お気に入り") {
                ForEach(favorites) { favorite in
                    FavoriteTile(favorite: favorite)
                }
            }
        }

        ForEach(Array(appleLibraryVisible.enumerated()), id: \.element.id) { offset, shelf in
            Shelf(index: favoriteOffset + offset + 1, label: "Apple Music", labelTint: StreamingService.appleMusic.tint, title: shelf.title) {
                ForEach(shelf.items) { item in CatalogTile(collection: item) }
            }
        }

        // Apple Music で絞り込んだときだけ、使えない機能を一行で案内する（「すべて」では出さない）
        if filter == .appleMusic, music.isAuthorized, music.apiProblem != nil || music.libraryProblem != nil {
            AppleMusicLimitedNote()
                .padding(.horizontal, 20)
        }

        ForEach(Array(appleVisible.enumerated()), id: \.element.id) { offset, shelf in
            Shelf(index: favoriteOffset + appleLibraryVisible.count + offset + 1, label: "Apple Music", labelTint: StreamingService.appleMusic.tint, title: shelf.title) {
                ForEach(shelf.items) { item in AppleMusicTile(item: item) }
            }
        }

        ForEach(Array(spotifyVisible.enumerated()), id: \.element.id) { offset, shelf in
            Shelf(index: favoriteOffset + appleLibraryVisible.count + appleVisible.count + offset + 1, label: "Spotify",
                  labelTint: StreamingService.spotify.tint, title: shelf.title) {
                ForEach(shelf.items) { item in CatalogTile(collection: item) }
            }
        }

        if let filter {
            if needsCard(filter) {
                ServiceConnectCard(service: filter)
                    .padding(.horizontal, 20)
            }
            if favorites.isEmpty && appleVisible.isEmpty && appleLibraryVisible.isEmpty && spotifyVisible.isEmpty
                && !needsCard(filter) && music.apiProblem == nil && music.libraryProblem == nil {
                ContentUnavailableView("\(filter.displayName)の項目がありません",
                                       systemImage: "music.note.house",
                                       description: Text("Sonosアプリで\(filter.displayName)の曲をお気に入りに登録すると、ここに表示されます。"))
            }
        } else if !unconnected.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    IndexLabel(index: nil, text: "Services")
                    Text("音楽サービスをつなぐ")
                        .font(.system(.title2, weight: .bold))
                }
                .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(unconnected) { service in
                            ServiceConnectCard(service: service)
                                .frame(width: 300)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func needsCard(_ service: StreamingService) -> Bool {
        switch service {
        case .appleMusic: return !music.isAuthorized
        case .spotify: return !spotify.isConnected
        }
    }

    private func reload() async {
        await store.loadFavorites()
        async let spotifyItems = spotify.homeShelves()
        await loadApple()
        spotifyShelves = await spotifyItems
    }

    /// Apple Music のライブラリ（自分のプレイリスト・アルバム）と、最近再生・おすすめ
    private func loadApple() async {
        guard music.isAuthorized else { return }
        let playlists = await music.libraryPlaylists()
        let albums = await music.libraryAlbums()
        var library: [CatalogShelf] = []
        if !playlists.isEmpty { library.append(CatalogShelf(service: .appleMusic, title: "ライブラリのプレイリスト", items: playlists)) }
        if !albums.isEmpty { library.append(CatalogShelf(service: .appleMusic, title: "ライブラリのアルバム", items: albums)) }
        appleLibraryShelves = library
        appleShelves = await music.homeShelves()
    }
}

/// ホーム上部。Apple Music と同じく大きな「ホーム」の見出しと、上にスピーカー・設定のボタン
private struct HomeHeader: View {
    @Environment(SonosStore.self) private var store
    @Binding var showRooms: Bool
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let group = store.selectedGroup {
                    Button { showRooms = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if store.isPlaying {
                                Image(systemName: "waveform")
                                    .font(.system(size: 11, weight: .bold))
                                    .symbolEffect(.variableColor.iterative, isActive: true)
                            }
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("スピーカー: \(group.name)")
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Theme.surface, in: Circle())
                }
                .accessibilityLabel("設定")
            }
            .padding(.bottom, 4)

            Text("ホーム")
                .font(.largeTitle.bold())
        }
        .padding(.horizontal, 20)
    }
}

struct Shelf<Content: View>: View {
    var index: Int?
    var label: String = ""
    var labelTint: Color?
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !label.isEmpty {
                    IndexLabel(index: index, text: label, tint: labelTint)
                }
                Text(title)
                    .font(.title2.bold())
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    content
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// Sonosのお気に入り。プレイリスト・アルバムは押すと開き（曲を選んで再生できる）、曲やラジオは押すと再生する
struct FavoriteTile: View {
    @Environment(SonosStore.self) private var store
    @Environment(SpotifyService.self) private var spotify
    let favorite: DIDLItem

    var body: some View {
        if let collection = openableCollection {
            NavigationLink { CatalogCollectionView(collection: collection) } label: { tile }
                .buttonStyle(PressableStyle())
                .contextMenu { menu }
        } else {
            Button { store.playFavorite(favorite) } label: { tile }
                .buttonStyle(PressableStyle())
                .contextMenu { menu }
        }
    }

    /// 開いて曲の一覧を出せるお気に入り（Apple Music のプレイリスト・アルバム、Spotify にログイン済みならそのプレイリスト・アルバム）
    private var openableCollection: CatalogCollection? {
        guard let uri = favorite.resURI?.removingPercentEncoding, uri.hasPrefix("x-rincon-cpcontainer:") else { return nil }
        let artwork = favorite.artworkURL(host: store.artworkHost)
        func id(after marker: String) -> String? {
            guard let range = uri.range(of: marker, options: .caseInsensitive) else { return nil }
            let rest = uri[range.upperBound...]
            let value = rest.prefix { $0 != "?" && $0 != "&" && $0 != "/" }
            return value.isEmpty ? nil : String(value)
        }
        switch StreamingService.detect(favorite) {
        case .appleMusic:
            if let playlist = id(after: "libraryplaylist:") {
                return CatalogCollection(service: .appleMusic, kind: .playlist, serviceID: playlist, title: favorite.title,
                                         subtitle: "お気に入り", artworkURL: artwork)
            }
            if let album = id(after: "album:"), album.allSatisfy(\.isNumber) {
                return CatalogCollection(service: .appleMusic, kind: .album, serviceID: album, title: favorite.title,
                                         subtitle: "お気に入り", artworkURL: artwork)
            }
        case .spotify where spotify.isConnected:
            for kind in [ServiceContent.Kind.playlist, .album] {
                if let value = id(after: "spotify:\(kind.rawValue):") {
                    return CatalogCollection(service: .spotify, kind: kind, serviceID: value, title: favorite.title,
                                             subtitle: "お気に入り", artworkURL: artwork)
                }
            }
        default:
            break
        }
        return nil
    }

    private var tile: some View {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: favorite.artworkURL(host: store.artworkHost), cornerRadius: 10, seed: favorite.title)
                    .frame(width: 160, height: 160)
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent && store.isPlaying {
                            Image(systemName: "waveform")
                                .font(.system(size: 12, weight: .bold))
                                .symbolEffect(.variableColor.iterative, isActive: true)
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(8)
                        }
                    }
                Text(favorite.title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let service = StreamingService.detect(favorite) {
                    ServiceTag(service: service)
                } else {
                    Text((favorite.serviceDescription ?? "").uppercased())
                        .font(Theme.label(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 160, alignment: .leading)
    }

    @ViewBuilder
    private var menu: some View {
            Button("再生", systemImage: "play.fill") { store.playFavorite(favorite) }
            if let uri = favorite.resURI, !SonosStore.isStreamURI(uri) {
                Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    store.enqueue(favorite, mode: .next)
                }
                Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    store.enqueue(favorite, mode: .end)
                }
            }
    }

    private var isCurrent: Bool {
        guard let title = store.track?.title, !title.isEmpty else { return false }
        return title == favorite.title || store.track?.stationName == favorite.title
    }
}

struct AppleMusicTile: View {
    let item: AppleMusicItem

    var body: some View {
        NavigationLink {
            switch item {
            case .album(let album): AppleMusicAlbumView(album: album)
            case .playlist(let playlist): AppleMusicPlaylistView(playlist: playlist)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: item.artworkURL(400), cornerRadius: 10, seed: item.title)
                    .frame(width: 160, height: 160)
                Text(item.title).font(.subheadline).lineLimit(1)
                Text(item.subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
    }
}

struct AppleMusicConnectCard: View {
    var body: some View { ServiceConnectCard(service: .appleMusic) }
}

struct ConnectView: View {
    @Environment(SonosStore.self) private var store
    @State private var manualHost = ""
    @State private var adding = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 54))
                .foregroundStyle(Color.appAccent)
                .symbolEffect(.pulse, isActive: store.connection == .searching)
            Text(store.connection == .unreachable ? "スピーカーに接続できません" : "Sonosスピーカーを探しています…")
                .font(.title3.bold())
            Text("iPhoneがSonosと同じWi-Fiに接続されていることを確認してください。「ローカルネットワーク」へのアクセスを許可していない場合は、設定アプリ > プライバシーとセキュリティ > ローカルネットワーク で許可してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("IPアドレスを直接入力").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    TextField("例: 192.168.1.20", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button {
                        adding = true
                        Task {
                            _ = await store.addManualHost(manualHost)
                            adding = false
                        }
                    } label: {
                        if adding { ProgressView() } else { Text("接続") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualHost.isEmpty || adding)
                }
            }
            .padding(.top, 8)

            Button("もう一度探す") { store.rediscover() }
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
    }
}

/// Apple Music API が使えないときの控えめな案内
struct AppleMusicLimitedNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
            Text("自分のプレイリストは、純正のSonosアプリで「お気に入り」に追加すると、ここに表示されて再生できます。")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
