import SwiftUI

struct QueuePanel: View {
    @Environment(SonosStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ModeChip(symbol: "shuffle", isOn: store.isShuffleOn) { store.toggleShuffle() }
                ModeChip(symbol: store.playMode.repeatMode == .one ? "repeat.1" : "repeat",
                         isOn: store.playMode.repeatMode != .off) { store.cycleRepeat() }
            }

            if let spotify = store.spotifyConnect {
                SpotifyUpNext(info: spotify)
            } else {
                sonosQueue
            }
        }
        .padding(.bottom, 8)
        .task { await store.refreshQueue() }
    }

    @ViewBuilder
    private var sonosQueue: some View {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("次に再生").font(.headline)
                    if !store.isPlayingQueue, store.track != nil {
                        Text("現在はキュー以外のソースを再生中です")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    } else if !store.queue.isEmpty {
                        Text("長押しして並べ替え・左にスワイプして削除")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
            }

            if store.queue.isEmpty {
                Text("キューは空です")
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(store.queue.enumerated()), id: \.element.id) { index, item in
                            QueueRow(item: item,
                                     host: store.artworkHost,
                                     isCurrent: store.isPlayingQueue && index + 1 == store.currentTrackNumber,
                                     isPlaying: store.isPlaying,
                                     isPast: store.isPlayingQueue && index + 1 < store.currentTrackNumber)
                            .onTapGesture { store.playQueueItem(at: index) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: Self.trailingBleed))
                            .listRowSeparatorTint(.white.opacity(0.12))
                            // List を右へ広げた分、区切り線も行の中身の右端で止める
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                            // 削除は左スワイプだけ（編集モードの赤い削除ボタンは出さない）
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.removeQueueItems(at: IndexSet(integer: index))
                                } label: {
                                    Label("削除", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .tint(.red)
                            }
                        }
                        // 編集モードにしなくても、長押ししてドラッグすれば並べ替えられる
                        .onMove { store.moveQueueItem(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // 削除ボタンは List の右端を基準に置かれるので、List だけを右へ広げて行の中身は同じだけ内側に戻す。
                    // これで行の見た目は変わらず、削除ボタンの中心が上下の行の並べ替えつまみ（≡）の中心にそろう
                    .padding(.trailing, -Self.trailingBleed)
                    .onAppear { scrollToCurrent(proxy) }
                    .onChange(of: store.currentTrackNumber) { _, _ in
                        withAnimation { scrollToCurrent(proxy) }
                    }
                }
            }
    }

    /// List を右へ広げる幅。
    /// 削除ボタン（直径約 49pt の丸）は List の右端から約 10pt 内側に出る。この幅にすると、ボタンの中心が
    /// 上下の行の並べ替えつまみ（≡）の中心と 1pt 以内でそろう（iPhone 12 Pro のシミュレータで実測）
    private static let trailingBleed: CGFloat = 25.5

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        let index = store.currentTrackNumber - 1
        guard store.isPlayingQueue, store.queue.indices.contains(index) else { return }
        proxy.scrollTo(store.queue[index].id, anchor: .top)
    }
}

/// Spotify Connect で再生中は、次の曲は Spotify が決める（Sonos のキューは使われない）
private struct SpotifyUpNext: View {
    let info: SonosStore.SpotifyConnectInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("次に再生").font(.headline)
                Text(info.singleTrack
                     ? "Spotifyで1曲だけ再生しているため、次からはSpotifyのおすすめ（自動再生）が流れます。続けて聴きたい場合は、アルバムやプレイリストのリンクから再生してください。"
                     : "Spotifyの「\(info.contextName ?? "アルバム")」を再生中です。次の曲はSpotifyが決めます。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let name = info.nextName {
                HStack(spacing: 12) {
                    ArtworkView(url: info.nextImageURL, cornerRadius: 8, seed: name)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).lineLimit(1)
                        Text(info.nextArtist ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct QueueRow: View {
    let item: DIDLItem
    let host: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let isPast: Bool

    /// 日本語表記（Sonos がローマ字で返す Apple Music の曲）。見えている行だけ調べる
    @State private var names: TrackNames?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.artworkURL(host: host), cornerRadius: 8, seed: item.title)
                .frame(width: 46, height: 46)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.45))
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                            .foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(names?.title ?? item.title).lineLimit(1)
                Text(names?.artist ?? item.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let duration = item.durationSeconds {
                Text(TimeFormat.display(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            // 並べ替えられることを示すつまみ（長押しでドラッグ）
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.leading, 4)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .opacity(isPast ? 0.45 : 1)
        .contentShape(Rectangle())
        .task(id: item.id) { await localize() }
    }

    private func localize() async {
        let uri = item.resURI ?? ""
        guard StreamingService.detect(in: uri) == .appleMusic,
              TrackNameLocalizer.needsLookup(title: item.title, artist: item.artist ?? "") else { return }
        let artist = item.artist ?? ""
        let duration = item.durationSeconds ?? 0
        let songID = AppleMusicSonos.catalogSongID(in: uri)
        // 回数制限で調べられなかったときは、少し待ってから調べ直す（行が見えている間だけ）
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(15)) }
            guard !Task.isCancelled else { return }
            if let found = await TrackNameLocalizer.shared.names(title: item.title, artist: artist, album: item.album,
                                                                  duration: duration, catalogSongID: songID) {
                names = found
                return
            }
            guard await TrackNameLocalizer.shared.isPending(title: item.title, artist: artist, album: item.album,
                                                            duration: duration, catalogSongID: songID) else { return }
        }
    }
}
