import MusicKit
import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case appleMusic = "Apple Music"
        case library = "ライブラリ"
        var id: String { rawValue }
    }

    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    @State private var query = ""
    @State private var scope: Scope = .appleMusic
    @State private var results = AppleMusicSearchResults()
    @State private var libraryResults: [LibrarySection] = []

    struct LibrarySection: Identifiable {
        let title: String
        let items: [DIDLItem]
        var id: String { title }
    }
    @State private var searching = false

    var body: some View {
        List {
            Picker("検索対象", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            switch scope {
            case .appleMusic: appleMusicResults
            case .library: libraryResultList
            }
        }
        .listStyle(.plain)
        .navigationTitle("検索")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "アーティスト、曲、アルバムなど")
        .overlay {
            if searching { ProgressView() }
        }
        .task(id: "\(scope.rawValue)|\(query)") {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else {
                results = AppleMusicSearchResults()
                libraryResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            switch scope {
            case .appleMusic:
                guard music.isAuthorized else { return }
                if let found = try? await music.search(term), !Task.isCancelled { results = found }
            case .library:
                await searchLibrary(term)
            }
        }
    }

    // MARK: Apple Music

    @ViewBuilder
    private var appleMusicResults: some View {
        if !music.isAuthorized {
            AppleMusicConnectCard()
                .listRowSeparator(.hidden)
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
                                ArtworkView(url: artist.artwork?.url(width: 120, height: 120), cornerRadius: 24, placeholderSymbol: "music.mic")
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
