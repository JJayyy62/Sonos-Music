import AuthenticationServices
import SwiftUI

// MARK: - Service tag & chips

/// 「● SPOTIFY」のような小さなサービス表示
struct ServiceTag: View {
    let service: StreamingService
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(service.tint).frame(width: size * 0.55, height: size * 0.55)
            Text(service.label)
                .font(Theme.label(size))
                .tracking(1)
                .foregroundStyle(service.tint.opacity(0.9))
        }
        .lineLimit(1)
    }
}

/// 横並びの切り替えチップ（ホームの絞り込み・検索対象）
struct ChipBar<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        let tint: Color
        var id: Value { value }
    }

    let items: [Item]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    let selected = item.value == selection
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { selection = item.value }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(item.tint).frame(width: 7, height: 7)
                            Text(item.title).font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(selected ? Theme.onAccent : .white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Capsule().fill(selected ? AnyShapeStyle(item.tint) : AnyShapeStyle(Theme.surface)))
                        .overlay(Capsule().strokeBorder(selected ? .clear : Theme.hairline))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension ChipBar where Value == StreamingService? {
    /// 「すべて / Apple Music / Spotify」
    static func services(selection: Binding<StreamingService?>) -> ChipBar {
        ChipBar(items: [Item(value: nil, title: "すべて", tint: Theme.accent)]
                + StreamingService.allCases.map { Item(value: $0, title: $0.displayName, tint: $0.tint) },
                selection: selection)
    }
}

// MARK: - Tiles & rows

/// Spotify などのアルバム／プレイリストのタイル
struct CatalogTile: View {
    let collection: CatalogCollection

    var body: some View {
        NavigationLink {
            CatalogCollectionView(collection: collection)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: collection.artworkURL, cornerRadius: 10, seed: collection.title)
                    .frame(width: 160, height: 160)
                Text(collection.title).font(.subheadline).lineLimit(1)
                Text(collection.subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
    }
}

struct CatalogTrackButton: View {
    @Environment(SonosStore.self) private var store
    let track: CatalogTrack
    var showsArtwork = true

    var body: some View {
        Button { store.play(track.content) } label: {
            TrackRow(title: track.title,
                     subtitle: [track.artist, track.album].compactMap { $0?.nilIfEmpty }.joined(separator: " · "),
                     artworkURL: showsArtwork ? track.artworkURL : nil,
                     trailing: track.duration.map(TimeFormat.display),
                     explicit: track.explicit)
        }
        .buttonStyle(.plain)
        .contextMenu { EnqueueMenu(content: track.content) }
    }
}

/// 「次に再生」「最後に追加」
struct EnqueueMenu: View {
    @Environment(SonosStore.self) private var store
    let content: ServiceContent

    var body: some View {
        Button("再生", systemImage: "play.fill") { store.play(content) }
        Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") { store.enqueue(content, mode: .next) }
        Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") { store.enqueue(content, mode: .end) }
    }
}

// MARK: - Detail screens

/// Spotify・Apple Music（公開検索API／ライブラリ）のアルバム／プレイリスト
struct CatalogCollectionView: View {
    @Environment(SonosStore.self) private var store
    let collection: CatalogCollection

    @State private var tracks: [CatalogTrack] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        List {
            Section {
                AlbumHeader(
                    artworkURL: collection.artworkURL,
                    title: collection.title,
                    subtitle: collection.subtitle,
                    detail: [collection.service.displayName, collection.detail].compactMap { $0 }.joined(separator: " · "),
                    badges: [],
                    play: { store.play(collection.content, shuffle: false) },
                    shuffle: { store.play(collection.content, shuffle: true) })
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    Button {
                        store.play(collection.content, startIndex: index)
                    } label: {
                        TrackRow(title: track.title,
                                 subtitle: collection.kind == .album && track.artist == collection.subtitle ? nil : track.artist,
                                 artworkURL: collection.kind == .album ? nil : track.artworkURL,
                                 leadingNumber: collection.kind == .album ? (track.number ?? index + 1) : nil,
                                 trailing: track.duration.map(TimeFormat.display))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { EnqueueMenu(content: track.content) }
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
        .overlay {
            if loading && tracks.isEmpty { ProgressView() }
            else if failed { ContentUnavailableView("曲の一覧を読み込めませんでした", systemImage: "exclamationmark.triangle",
                                                    description: Text("上の「再生」からはそのまま再生できます。")) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") { store.enqueue(collection.content, mode: .next) }
                    Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") { store.enqueue(collection.content, mode: .end) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            do {
                tracks = try await CatalogLoader.tracks(of: collection)
            } catch {
                failed = true
            }
            loading = false
        }
    }
}

struct CatalogArtistView: View {
    let artist: CatalogArtist

    @State private var topTracks: [CatalogTrack] = []
    @State private var albums: [CatalogCollection] = []

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(url: artist.artworkURL, cornerRadius: 110, placeholderSymbol: "music.mic", seed: artist.name)
                        .frame(width: 200, height: 200)
                    Text(artist.name).font(.system(.title, weight: .heavy))
                    ServiceTag(service: artist.service)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if !topTracks.isEmpty {
                Section("人気の曲") {
                    ForEach(topTracks.prefix(10)) { track in CatalogTrackButton(track: track) }
                }
            }
            if !albums.isEmpty {
                Section("アルバム") {
                    ForEach(albums) { album in
                        NavigationLink {
                            CatalogCollectionView(collection: album)
                        } label: {
                            TrackRow(title: album.title, subtitle: album.detail, artworkURL: album.artworkURL)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .inkBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let top = CatalogLoader.artistTopTracks(artist)
            albums = (try? await CatalogLoader.artistAlbums(artist)) ?? []
            topTracks = await top
        }
    }
}

// MARK: - Connect cards

/// サービスごとの「つなぐ」カード。ホームと検索で使う
struct ServiceConnectCard: View {
    @Environment(AppleMusicService.self) private var music
    @Environment(SpotifyService.self) private var spotify
    let service: StreamingService
    @State private var showLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ServiceTag(service: service)
            Text(title).font(.system(.title3, weight: .bold))
            Text(message).font(.subheadline).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                switch service {
                case .appleMusic:
                    CardButton(title: "連携する", symbol: "link", tint: service.tint) {
                        Task { await music.requestAuthorization() }
                    }
                case .spotify:
                    SpotifyLoginButton()
                    CardButton(title: "リンクから再生", symbol: "link", tint: nil) { showLink = true }
                }
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [service.tint.opacity(0.16), Theme.surface],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        }
        .sheet(isPresented: $showLink) {
            LinkPlaySheet(preferred: service).presentationDetents([.medium, .large])
        }
    }

    private var title: String {
        switch service {
        case .appleMusic: return "Apple Musicと連携"
        case .spotify: return spotify.clientID.isEmpty ? "Spotifyを設定" : "Spotifyにログイン"
        }
    }

    private var message: String {
        switch service {
        case .appleMusic:
            return "連携すると、Apple Musicのカタログ検索・おすすめの表示、曲ごとのロスレス / Dolby Atmos情報の取得ができます。再生はSonosに登録済みのApple Musicアカウントで行われます。"
        case .spotify:
            return spotify.clientID.isEmpty
                ? "Spotifyの検索・プレイリストの表示には、設定 > 音楽サービス > Spotify で Client ID の登録が必要です。共有リンクからの再生は Client ID なしで使えます（最初に1回、SonosアプリでSpotifyの曲をお気に入りに追加しておいてください）。"
                : "ログインすると、Spotifyの検索・保存したアルバム・プレイリストを表示できます。再生はSonosに登録済みのSpotifyアカウントで行われます。"
        }
    }
}

private struct CardButton: View {
    let title: String
    let symbol: String
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint == nil ? .white : Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(tint ?? Theme.surfaceRaised))
                .overlay(Capsule().strokeBorder(tint == nil ? Theme.hairline : .clear))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Spotify のログイン（Client ID 未設定なら設定画面へ案内）
struct SpotifyLoginButton: View {
    @Environment(SpotifyService.self) private var spotify
    @Environment(SonosStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var showSettings = false

    var body: some View {
        CardButton(title: spotify.clientID.isEmpty ? "設定する" : "ログイン",
                   symbol: spotify.clientID.isEmpty ? "gearshape" : "person.crop.circle",
                   tint: StreamingService.spotify.tint) {
            if spotify.clientID.isEmpty {
                showSettings = true
            } else {
                Task { await login() }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { ServiceSettingsView(service: .spotify) }
        }
    }

    private func login() async {
        do {
            let url = try spotify.authorizationURL()
            let callback = try await webAuthenticationSession.authenticate(
                using: url, callbackURLScheme: SpotifyService.callbackScheme, preferredBrowserSession: .shared)
            try await spotify.completeLogin(callback: callback)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            store.show(error)
        }
    }
}

// MARK: - Link playback

/// 共有リンク（Apple Music / Spotify）を貼り付けて再生する
struct LinkPlaySheet: View {
    @Environment(SonosStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var preferred: StreamingService?

    @State private var text = ""
    @State private var title = ""

    private var parsed: ServiceContent? { ServiceLink.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...4)
                    Button("クリップボードから貼り付け", systemImage: "doc.on.clipboard") {
                        if let string = UIPasteboard.general.string { text = string }
                    }
                } header: {
                    Text("共有リンク")
                } footer: {
                    Text(hint)
                }

                if let parsed, store.detectedSerials[parsed.service] == nil {
                    // Sonos 上のアカウント番号とトークンはお気に入りなどからしか分からない。
                    // 分からないまま再生すると Sonos に「アクセスを拒否しました」と断られるので、先に案内する
                    Section {
                        Label {
                            Text("Sonos上の\(parsed.service.displayName)のアカウントがまだ分かりません。このまま再生すると「アクセスを拒否しました」になることがあります。純正のSonosアプリで\(parsed.service.displayName)の曲を1つお気に入りに追加してから、Ariaを開き直してください。")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                if let parsed {
                    Section("再生する内容") {
                        HStack {
                            ServiceTag(service: parsed.service, size: 11)
                            Spacer()
                            Text(kindLabel(parsed.kind)).foregroundStyle(Theme.textSecondary)
                        }
                        TextField("名前（任意・キューに表示されます）", text: $title)
                        Button {
                            store.play(content(parsed))
                            dismiss()
                        } label: {
                            Label("再生", systemImage: "play.fill").font(.headline)
                        }
                        Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            store.enqueue(content(parsed), mode: .next)
                            dismiss()
                        }
                        Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") {
                            store.enqueue(content(parsed), mode: .end)
                            dismiss()
                        }
                    }
                } else if !text.isEmpty {
                    Section {
                        Label("このリンクは読み取れませんでした", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .inkBackground()
            .navigationTitle("リンクから再生")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .onAppear {
                if text.isEmpty, let string = UIPasteboard.general.string, ServiceLink.parse(string) != nil {
                    text = string
                }
            }
        }
    }

    private var hint: String {
        switch parsed?.service ?? preferred {
        case .spotify: return "Spotifyアプリで「共有 > リンクをコピー」を選び、ここに貼り付けてください。"
        case .appleMusic: return "ミュージックアプリで「共有 > リンクをコピー」を選び、ここに貼り付けてください。"
        default: return "Apple Music・Spotify の共有リンクに対応しています。再生はSonosに登録済みの各サービスのアカウントで行われます。"
        }
    }

    private func kindLabel(_ kind: ServiceContent.Kind) -> String {
        switch kind {
        case .track: return "曲"
        case .album: return "アルバム"
        case .playlist: return "プレイリスト"
        }
    }

    private func content(_ parsed: ServiceContent) -> ServiceContent {
        var content = parsed
        let name = title.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { content.title = name }
        return content
    }
}

// MARK: - Library lists

/// ライブラリのプレイリスト／アルバムの一覧
struct CatalogListView: View {
    let title: String
    let load: @MainActor () async -> [CatalogCollection]
    var problem: () -> String? = { nil }

    @State private var items: [CatalogCollection] = []
    @State private var loading = true

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink {
                    CatalogCollectionView(collection: item)
                } label: {
                    TrackRow(title: item.title, subtitle: item.subtitle, artworkURL: item.artworkURL)
                }
                .contextMenu { EnqueueMenu(content: item.content) }
            }
        }
        .listStyle(.plain)
        .inkBackground()
        .navigationTitle(title)
        .overlay {
            if loading {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView("項目がありません", systemImage: "music.note.list",
                                       description: Text(problem() ?? "Apple Musicのライブラリに項目がないか、まだ同期されていません。"))
            }
        }
        .task {
            items = await load()
            loading = false
        }
        .refreshable { items = await load() }
    }
}
