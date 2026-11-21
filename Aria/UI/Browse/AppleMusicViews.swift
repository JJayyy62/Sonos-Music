import MusicKit
import SwiftUI

struct AppleMusicAlbumView: View {
    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    let album: Album

    @State private var tracks: [Track] = []
    @State private var badges: [AudioQuality.Badge] = []

    private var content: AppleMusicSonos.Content { .album(id: album.id.rawValue, title: album.title) }

    var body: some View {
        List {
            Section {
                AlbumHeader(
                    artworkURL: album.artwork?.url(width: 600, height: 600),
                    title: album.title,
                    subtitle: album.artistName,
                    detail: [album.genreNames.first, album.releaseDate.map { String(Calendar.current.component(.year, from: $0)) }]
                        .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                    badges: badges,
                    play: { store.playAppleMusic(content, shuffle: false) },
                    shuffle: { store.playAppleMusic(content, shuffle: true) })
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        store.playAppleMusic(content, startIndex: index)
                    } label: {
                        TrackRow(title: track.title,
                                 subtitle: track.artistName == album.artistName ? nil : track.artistName,
                                 leadingNumber: track.trackNumber ?? index + 1,
                                 trailing: track.duration.map(TimeFormat.display))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { songMenu(id: track.id.rawValue, title: track.title) }
                }
            } footer: {
                if !tracks.isEmpty {
                    Text("\(tracks.count)曲、\(TimeFormat.display(tracks.compactMap(\.duration).reduce(0, +)))")
                }
            }
        }
        .listStyle(.plain)
        .inkBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") { store.enqueueAppleMusic(content, mode: .next) }
                    Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") { store.enqueueAppleMusic(content, mode: .end) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            if let detailed = try? await album.with([.tracks]), let loaded = detailed.tracks {
                tracks = Array(loaded)
            }
            let traits = Set(await music.audioTraits(type: .albums, id: album.id.rawValue))
            var found: [AudioQuality.Badge] = []
            if traits.contains("atmos") || traits.contains("dolby-atmos") { found.append(.dolbyAtmos) }
            if traits.contains("hi-res-lossless") { found.append(.hiResLossless) }
            else if traits.contains("lossless") { found.append(.lossless) }
            badges = found
        }
    }

    @ViewBuilder
    private func songMenu(id: String, title: String) -> some View {
        Button("この曲だけ再生", systemImage: "play") { store.playAppleMusic(.song(id: id, title: title)) }
        Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") { store.enqueueAppleMusic(.song(id: id, title: title), mode: .next) }
        Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") { store.enqueueAppleMusic(.song(id: id, title: title), mode: .end) }
    }
}

struct AppleMusicPlaylistView: View {
    @Environment(SonosStore.self) private var store
    let playlist: Playlist

    @State private var tracks: [Track] = []

    private var content: AppleMusicSonos.Content { .playlist(id: playlist.id.rawValue, title: playlist.name) }
    private var playable: Bool { AppleMusicSonos.isCatalogPlaylistID(playlist.id.rawValue) }

    var body: some View {
        List {
            Section {
                AlbumHeader(
                    artworkURL: playlist.artwork?.url(width: 600, height: 600),
                    title: playlist.name,
                    subtitle: playlist.curatorName,
                    detail: playable ? nil : "このプレイリストはSonosから再生できません",
                    badges: [],
                    play: { store.playAppleMusic(content, shuffle: false) },
                    shuffle: { store.playAppleMusic(content, shuffle: true) })
                .disabled(!playable)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        if playable {
                            store.playAppleMusic(content, startIndex: index)
                        } else {
                            store.playAppleMusic(.song(id: track.id.rawValue, title: track.title))
                        }
                    } label: {
                        TrackRow(title: track.title, subtitle: track.artistName,
                                 artworkURL: track.artwork?.url(width: 120, height: 120),
                                 trailing: track.duration.map(TimeFormat.display))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            store.enqueueAppleMusic(.song(id: track.id.rawValue, title: track.title), mode: .next)
                        }
                        Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") {
                            store.enqueueAppleMusic(.song(id: track.id.rawValue, title: track.title), mode: .end)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .inkBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let detailed = try? await playlist.with([.tracks]), let loaded = detailed.tracks {
                tracks = Array(loaded)
            }
        }
    }
}

struct AppleMusicArtistView: View {
    @Environment(SonosStore.self) private var store
    let artist: Artist

    @State private var topSongs: [Song] = []
    @State private var albums: [Album] = []

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(url: artist.artwork?.url(width: 500, height: 500), cornerRadius: 110, placeholderSymbol: "music.mic", seed: artist.name)
                        .frame(width: 220, height: 220)
                    Text(artist.name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if !topSongs.isEmpty {
                Section("トップソング") {
                    ForEach(topSongs.prefix(10)) { song in
                        SongRow(song: song)
                    }
                }
            }
            if !albums.isEmpty {
                Section("アルバム") {
                    ForEach(albums) { album in
                        NavigationLink {
                            AppleMusicAlbumView(album: album)
                        } label: {
                            TrackRow(title: album.title,
                                     subtitle: album.releaseDate.map { String(Calendar.current.component(.year, from: $0)) },
                                     artworkURL: album.artwork?.url(width: 120, height: 120))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .inkBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let detailed = try? await artist.with([.topSongs, .albums]) {
                topSongs = detailed.topSongs.map { Array($0) } ?? []
                albums = detailed.albums.map { Array($0) } ?? []
            }
        }
    }
}
