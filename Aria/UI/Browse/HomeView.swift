import SwiftUI

struct HomeView: View {
    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    @State private var shelves: [AppleMusicShelf] = []
    @State private var showSettings = false
    @State private var showRooms = false

    var body: some View {
        ScrollView {
            if store.groups.isEmpty {
                ConnectView()
                    .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !store.favorites.isEmpty {
                        Shelf(title: "Sonosお気に入り") {
                            ForEach(store.favorites) { favorite in
                                FavoriteTile(favorite: favorite)
                            }
                        }
                    }

                    if !music.isAuthorized {
                        AppleMusicConnectCard()
                            .padding(.horizontal)
                    }

                    ForEach(shelves) { shelf in
                        Shelf(title: shelf.title) {
                            ForEach(shelf.items) { item in
                                AppleMusicTile(item: item)
                            }
                        }
                    }

                    if store.favorites.isEmpty && shelves.isEmpty && music.isAuthorized {
                        ContentUnavailableView("表示する項目がありません",
                                               systemImage: "music.note.house",
                                               description: Text("Sonosアプリでお気に入りを登録すると、ここに表示されます。"))
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("ホーム")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                RoomChip { showRooms = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("設定")
            }
        }
        .refreshable {
            await store.loadFavorites()
            shelves = await music.homeShelves()
        }
        .task(id: store.selectedGroup?.coordinator.uuid) {
            await store.loadFavorites()
        }
        .task(id: music.isAuthorized) {
            shelves = await music.homeShelves()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showRooms) {
            RoomPickerView().presentationDetents([.medium, .large])
        }
    }
}

struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content
                }
                .padding(.horizontal)
            }
        }
    }
}

struct FavoriteTile: View {
    @Environment(SonosStore.self) private var store
    let favorite: DIDLItem

    var body: some View {
        Button { store.playFavorite(favorite) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(url: favorite.artworkURL(host: store.artworkHost), cornerRadius: 10)
                    .frame(width: 160, height: 160)
                Text(favorite.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(favorite.serviceDescription ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
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
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(url: item.artworkURL(400), cornerRadius: 10)
                    .frame(width: 160, height: 160)
                Text(item.title).font(.subheadline).lineLimit(1)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

struct AppleMusicConnectCard: View {
    @Environment(AppleMusicService.self) private var music

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Apple Musicと連携", systemImage: "music.note")
                .font(.headline)
            Text("連携すると、Apple Musicのカタログ検索・おすすめの表示、曲ごとのロスレス / Dolby Atmos情報の取得ができます。再生はSonosに登録済みのApple Musicアカウントで行われます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("連携する") {
                Task { await music.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
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
