import SwiftUI

struct LibraryView: View {
    private struct Entry: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    private let sonosEntries = [
        Entry(id: "FV:2", title: "Sonosお気に入り", symbol: "star"),
        Entry(id: "SQ:", title: "Sonosプレイリスト", symbol: "music.note.list"),
    ]

    private let libraryEntries = [
        Entry(id: "A:ALBUMARTIST", title: "アーティスト", symbol: "music.mic"),
        Entry(id: "A:ALBUM", title: "アルバム", symbol: "square.stack"),
        Entry(id: "A:TRACKS", title: "曲", symbol: "music.note"),
        Entry(id: "A:GENRE", title: "ジャンル", symbol: "guitars"),
        Entry(id: "A:PLAYLISTS", title: "読み込んだプレイリスト", symbol: "list.bullet.rectangle"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(sonosEntries) { entry in row(entry) }
            }
            Section {
                ForEach(libraryEntries) { entry in row(entry) }
            } header: {
                Text("ミュージックライブラリ（NAS・共有フォルダ）")
            } footer: {
                Text("Sonosに登録したローカルの音楽ライブラリです。Apple Musicなどのストリーミングは「検索」から探せます。")
            }
        }
        .navigationTitle("ライブラリ")
    }

    private func row(_ entry: Entry) -> some View {
        NavigationLink {
            BrowseView(title: entry.title, objectID: entry.id)
        } label: {
            Label {
                Text(entry.title).font(.title3)
            } icon: {
                Image(systemName: entry.symbol).foregroundStyle(Color.appAccent)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Sonos の ContentDirectory を汎用的にブラウズする画面
struct BrowseView: View {
    @Environment(SonosStore.self) private var store
    let title: String
    let objectID: String
    var container: DIDLItem?

    @State private var items: [DIDLItem] = []
    @State private var loading = true
    @State private var failed = false

    private var tracks: [DIDLItem] { items.filter { !$0.isContainer } }
    private var showsAlbumHeader: Bool { container?.isAlbumLike == true && !tracks.isEmpty }

    var body: some View {
        List {
            if showsAlbumHeader, let container {
                Section {
                    AlbumHeader(
                        artworkURL: container.artworkURL(host: store.artworkHost) ?? tracks.first?.artworkURL(host: store.artworkHost),
                        title: container.title,
                        subtitle: container.artist ?? tracks.first?.artist,
                        detail: "\(tracks.count)曲",
                        badges: [],
                        play: { if let first = tracks.first { store.play(first, in: container, index: 0, shuffle: false) } },
                        shuffle: { if let first = tracks.first { store.play(first, in: container, index: 0, shuffle: true) } })
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if item.isBrowsable {
                        NavigationLink {
                            BrowseView(title: item.title, objectID: item.id, container: item)
                        } label: {
                            TrackRow(title: item.title, subtitle: item.artist, artworkURL: item.artworkURL(host: store.artworkHost))
                        }
                        .contextMenu { menu(for: item) }
                    } else {
                        Button {
                            let trackIndex = tracks.firstIndex(of: item) ?? 0
                            store.play(item, in: container?.resURI != nil ? container : nil, index: trackIndex)
                        } label: {
                            TrackRow(
                                title: item.title,
                                subtitle: showsAlbumHeader ? nil : [item.artist, item.serviceDescription].compactMap { $0 }.joined(separator: " · "),
                                artworkURL: showsAlbumHeader ? nil : item.artworkURL(host: store.artworkHost),
                                leadingNumber: showsAlbumHeader ? (item.trackNumber ?? index + 1) : nil,
                                trailing: item.durationSeconds.map(TimeFormat.display))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: item) }
                        .swipeActions(edge: .leading) {
                            Button { store.enqueue(item, mode: .next) } label: {
                                Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .tint(.indigo)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { store.enqueue(item, mode: .end) } label: {
                                Label("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(showsAlbumHeader ? "" : title)
        .navigationBarTitleDisplayMode(showsAlbumHeader ? .inline : .large)
        .overlay {
            if loading {
                ProgressView()
            } else if failed {
                ContentUnavailableView("読み込めませんでした", systemImage: "exclamationmark.triangle")
            } else if items.isEmpty {
                ContentUnavailableView("項目がありません", systemImage: "music.note.list")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func menu(for item: DIDLItem) -> some View {
        Button("再生", systemImage: "play.fill") { store.play(item) }
        if let uri = item.resURI, !SonosStore.isStreamURI(uri) {
            Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") { store.enqueue(item, mode: .next) }
            Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") { store.enqueue(item, mode: .end) }
        }
    }

    private func load() async {
        loading = items.isEmpty
        failed = false
        var collected: [DIDLItem] = []
        var start = 0
        do {
            repeat {
                let result = try await store.browse(objectID, start: start, count: 200)
                collected += result.items
                start += result.items.count
                if result.items.isEmpty || start >= result.total { break }
            } while start < 2000
            items = collected
        } catch {
            failed = items.isEmpty
        }
        loading = false
    }
}

/// Apple Music風のアルバム／プレイリストのヘッダー
struct AlbumHeader: View {
    let artworkURL: URL?
    let title: String
    let subtitle: String?
    let detail: String?
    let badges: [AudioQuality.Badge]
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(url: artworkURL, cornerRadius: 10)
                .frame(width: 250, height: 250)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .padding(.top, 8)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                    .multilineTextAlignment(.center)
            }
            if let detail {
                Text(detail).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if !badges.isEmpty {
                HStack(spacing: 8) {
                    ForEach(badges, id: \.self) { badge in
                        Label(Self.label(for: badge), systemImage: badge.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 14) {
                PillButton(title: "再生", symbol: "play.fill", action: play)
                PillButton(title: "シャッフル", symbol: "shuffle", action: shuffle)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    static func label(for badge: AudioQuality.Badge) -> String {
        switch badge {
        case .dolbyAtmos: return "Dolby Atmos"
        case .hiResLossless: return "Hi-Res Lossless"
        case .lossless: return "Lossless"
        case .dolbyAudio: return "Dolby Audio"
        case .surround: return "サラウンド"
        }
    }
}
