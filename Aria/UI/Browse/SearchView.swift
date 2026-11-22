import MusicKit
import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case appleMusic, spotify, library
        var id: String { rawValue }

        var service: StreamingService? { StreamingService(rawValue: rawValue) }
        var title: String { service?.displayName ?? "ライブラリ" }
        var tint: Color { service?.tint ?? Theme.accent }
    }

    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    @Environment(SpotifyService.self) private var spotify
    @State private var query = ""
    @AppStorage("searchScope") private var scope: Scope = .appleMusic
    @State private var results = AppleMusicSearchResults()
    @State private var spotifyResults = CatalogSearchResults()
    /// MusicKit が使えないときの Apple Music 検索結果（公開検索API）
    @State private var appleFallbackResults = CatalogSearchResults()
    @State private var searchError: String?
    @State private var showLink = false
    @State private var libraryResults: [LibrarySection] = []

    struct LibrarySection: Identifiable {
        let title: String
        let items: [DIDLItem]
        var id: String { title }
    }
    @State private var searching = false

    var body: some View {
        List {
            ChipBar(items: Scope.allCases.map { .init(value: $0, title: $0.title, tint: $0.tint) }, selection: $scope)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            switch scope {
            case .appleMusic: appleMusicResults
            case .spotify: spotifyResultList
            case .library: libraryResultList
            }
        }
        .listStyle(.plain)
        .inkBackground()
        .navigationTitle("検索")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showLink = true } label: { Image(systemName: "link") }
                    .accessibilityLabel("リンクから再生")
            }
        }
        .sheet(isPresented: $showLink) {
            LinkPlaySheet(preferred: scope.service).presentationDetents([.medium, .large])
        }
        .overlay {
            if searching { ProgressView() }
        }
        .task(id: "\(scope.rawValue)|\(query)") {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else {
                results = AppleMusicSearchResults()
                spotifyResults = CatalogSearchResults()
                appleFallbackResults = CatalogSearchResults()
                searchError = nil
                libraryResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            switch scope {
            case .appleMusic:
                searchError = nil
                if !music.usesFallbackSearch {
                    do {
                        let found = try await music.search(term)
                        if !Task.isCancelled {
                            results = found
                            appleFallbackResults = CatalogSearchResults()
                        }
                        return
                    } catch {
                        // 開発者トークンが取れないなどで MusicKit が使えない → 公開検索APIで探す
                    }
                }
                do {
                    let found = try await ITunesCatalog.search(term)
                    if !Task.isCancelled {
                        results = AppleMusicSearchResults()
                        appleFallbackResults = found
                    }
                } catch {
                    if !Task.isCancelled { searchError = "Apple Musicを検索できませんでした（\(error.localizedDescription)）" }
                }
            case .spotify:
                guard spotify.isConnected else { return }
                do {
                    let found = try await spotify.search(term)
                    if !Task.isCancelled { spotifyResults = found }
                } catch {
                    if !Task.isCancelled { store.show(error) }
                }
            case .library:
                await searchLibrary(term)
            }
        }
    }

    private var prompt: String {
        switch scope {
        case .library: return "ライブラリのアーティスト、曲、アルバム"
        default: return "\(scope.title)のアーティスト、曲、アルバムなど"
        }
    }

    // MARK: Spotify

    @ViewBuilder
    private var spotifyResultList: some View {
        if !spotify.isConnected {
            ServiceConnectCard(service: .spotify)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            catalogResultList(spotifyResults)
        }
    }

    /// Spotify と Apple Music（公開検索API）の共通の結果表示
    @ViewBuilder
    private func catalogResultList(_ found: CatalogSearchResults) -> some View {
        if !found.tracks.isEmpty {
            Section("曲") {
                ForEach(found.tracks) { track in CatalogTrackButton(track: track) }
            }
        }
        if !found.albums.isEmpty {
            Section("アルバム") {
                ForEach(found.albums) { album in collectionLink(album) }
            }
        }
        if !found.playlists.isEmpty {
            Section("プレイリスト") {
                ForEach(found.playlists) { playlist in collectionLink(playlist) }
            }
        }
        if !found.artists.isEmpty {
            Section("アーティスト") {
                ForEach(found.artists) { artist in
                        NavigationLink {
                            CatalogArtistView(artist: artist)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: artist.artworkURL, cornerRadius: 24, placeholderSymbol: "music.mic", seed: artist.name)
                                    .frame(width: 48, height: 48)
                                Text(artist.name)
                            }
                        }
                    }
                }
            }
    }

    private func collectionLink(_ collection: CatalogCollection) -> some View {
        NavigationLink {
            CatalogCollectionView(collection: collection)
        } label: {
            TrackRow(title: collection.title, subtitle: collection.subtitle, artworkURL: collection.artworkURL)
        }
        .contextMenu { EnqueueMenu(content: collection.content) }
    }

    // MARK: Apple Music

    @ViewBuilder
    private var appleMusicResults: some View {
        if let searchError {
            Label(searchError, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        if music.usesFallbackSearch || !appleFallbackResults.isEmpty {
            if !query.isEmpty, !appleFallbackResults.isEmpty {
                Text("簡易検索で表示しています（プレイリストは検索できません）。設定 > 音楽サービス > Apple Music で理由を確認できます。")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            catalogResultList(appleFallbackResults)
        } else {
            if !results.songs.isEmpty {
                Section("曲") {
                    ForEach(results.songs) { song in
                        SongRow(song: song)
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("アルバム") {
                    ForEach(results.albums) { album in
                        NavigationLink {
                            AppleMusicAlbumView(album: album)
                        } label: {
                            TrackRow(title: album.title, subtitle: album.artistName,
                                     artworkURL: album.artwork?.url(width: 120, height: 120))
                        }
                    }
                }
            }
            if !results.playlists.isEmpty {
                Section("プレイリスト") {
                    ForEach(results.playlists) { playlist in
                        NavigationLink {
                            AppleMusicPlaylistView(playlist: playlist)
                        } label: {
                            TrackRow(title: playlist.name, subtitle: playlist.curatorName,
                                     artworkURL: playlist.artwork?.url(width: 120, height: 120))
                        }
                    }
                }
            }
            if !results.artists.isEmpty {
                Section("アーティスト") {
                    ForEach(results.artists) { artist in
                        NavigationLink {
                            AppleMusicArtistView(artist: artist)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: artist.artwork?.url(width: 120, height: 120), cornerRadius: 24, placeholderSymbol: "music.mic", seed: artist.name)
                                    .frame(width: 48, height: 48)
                                Text(artist.name)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Library

    @ViewBuilder
    private var libraryResultList: some View {
        ForEach(libraryResults) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    if item.isBrowsable {
                        NavigationLink {
                            BrowseView(title: item.title, objectID: item.id, container: item)
                        } label: {
                            TrackRow(title: item.title, subtitle: item.artist, artworkURL: item.artworkURL(host: store.artworkHost))
                        }
                    } else {
                        Button { store.play(item) } label: {
                            TrackRow(title: item.title, subtitle: [item.artist, item.album].compactMap { $0 }.joined(separator: " · "),
                                     artworkURL: item.artworkURL(host: store.artworkHost))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") { store.enqueue(item, mode: .next) }
                            Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") { store.enqueue(item, mode: .end) }
                        }
                    }
                }
            }
        }
    }

    private func searchLibrary(_ term: String) async {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term
        var sections: [LibrarySection] = []
        for (title, prefix) in [("アーティスト", "A:ALBUMARTIST"), ("アルバム", "A:ALBUM"), ("曲", "A:TRACKS")] {
            if let result = try? await store.browse("\(prefix):\(encoded)", count: 30), !result.items.isEmpty {
                sections.append(LibrarySection(title: title, items: result.items))
            }
        }
        guard !Task.isCancelled else { return }
        libraryResults = sections
    }
}

struct SongRow: View {
    @Environment(SonosStore.self) private var store
    let song: Song

    var body: some View {
        Button {
            store.playAppleMusic(.song(id: song.id.rawValue, title: song.title))
        } label: {
            TrackRow(title: song.title,
                     subtitle: [song.artistName, song.albumTitle].compactMap { $0 }.joined(separator: " · "),
                     artworkURL: song.artwork?.url(width: 120, height: 120))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") {
                store.enqueueAppleMusic(.song(id: song.id.rawValue, title: song.title), mode: .next)
            }
            Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") {
                store.enqueueAppleMusic(.song(id: song.id.rawValue, title: song.title), mode: .end)
            }
        }
    }
}
