import SwiftUI

struct NowPlayingView: View {
    enum Panel { case none, lyrics, queue }

    @Environment(SonosStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel = .none
    @State private var palette = ArtworkPalette.fallback
    @State private var showRooms = false
    @State private var showQuality = false
    @Namespace private var artworkSpace

    var body: some View {
        ZStack {
            AnimatedMeshBackground(palette: palette, animate: store.isPlaying)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                grabber

                Group {
                    switch panel {
                    case .none:
                        largeArtwork
                    case .lyrics:
                        VStack(spacing: 0) {
                            compactHeader
                            LyricsPanel()
                        }
                    case .queue:
                        VStack(spacing: 0) {
                            compactHeader
                            QueuePanel()
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                PlayerControls(panel: $panel, showRooms: $showRooms, showQuality: $showQuality)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 6)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .sonosToast()
        .task(id: store.track?.artworkURL) {
            let next = await ArtworkPalette.load(from: store.track?.artworkURL)
            withAnimation(.easeInOut(duration: 1)) { palette = next }
        }
        .sheet(isPresented: $showRooms) {
            RoomPickerView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showQuality) {
            QualityInfoSheet(quality: store.quality, deviceName: store.selectedGroup?.name ?? "")
                .presentationDetents([.medium])
        }
    }

    private var grabber: some View {
        Button { dismiss() } label: {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("閉じる")
    }

    private var largeArtwork: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ArtworkView(url: store.track?.artworkURL, cornerRadius: 12, placeholderSymbol: placeholderSymbol)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .frame(width: side, height: side)
                .scaleEffect(store.isPlaying ? 1 : 0.8)
                .shadow(color: .black.opacity(store.isPlaying ? 0.45 : 0.25), radius: store.isPlaying ? 28 : 12, y: store.isPlaying ? 16 : 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.5, dampingFraction: 0.68), value: store.isPlaying)
                .onTapGesture { if store.lyrics.hasSyncedLyrics { setPanel(.lyrics) } }
        }
        .padding(.vertical, 18)
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(url: store.track?.artworkURL, cornerRadius: 6, placeholderSymbol: placeholderSymbol)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .onTapGesture { setPanel(.none) }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.track?.title ?? "再生停止中")
                    .font(.headline)
                    .lineLimit(1)
                Text(store.track?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PlayerMoreMenu(panel: $panel)
        }
        .padding(.vertical, 14)
    }

    private var placeholderSymbol: String {
        switch store.track?.kind {
        case .tv: return "tv"
        case .radio: return "dot.radiowaves.left.and.right"
        case .lineIn: return "cable.connector"
        default: return "music.note"
        }
    }

    private func setPanel(_ next: Panel) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { panel = next }
    }
}

// MARK: - Controls

struct PlayerControls: View {
    @Environment(SonosStore.self) private var store
    @Binding var panel: NowPlayingView.Panel
    @Binding var showRooms: Bool
    @Binding var showQuality: Bool

    var body: some View {
        VStack(spacing: 0) {
            if panel == .none {
                titleRow
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
            ProgressScrubber(showQuality: $showQuality)
            transport
                .padding(.vertical, 14)
            VolumeBar()
            bottomBar
                .padding(.top, 20)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.track?.title ?? "再生停止中")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PlayerMoreMenu(panel: $panel)
        }
    }

    private var subtitle: String {
        guard let track = store.track else { return store.selectedGroup?.name ?? "" }
        if track.kind == .tv { return store.selectedGroup?.name ?? "" }
        return track.artist.isEmpty ? (track.stationName ?? "") : track.artist
    }

    private var transport: some View {
        HStack {
            Spacer()
            Button { store.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 32))
            }
            Spacer()
            Button { store.togglePlayPause() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(TransportButtonStyle(size: 88))
            Spacer()
            Button { store.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 32))
            }
            Spacer()
        }
        .buttonStyle(TransportButtonStyle())
        .foregroundStyle(.white)
        .disabled(store.track?.kind == .tv || store.track?.kind == .lineIn)
        .sensoryFeedback(.impact(weight: .light), trigger: store.isPlaying)
    }

    private var bottomBar: some View {
        HStack {
            PanelToggleButton(symbol: panel == .lyrics ? "quote.bubble.fill" : "quote.bubble", isOn: panel == .lyrics) {
                toggle(.lyrics)
            }
            Spacer()
            Button { showRooms = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: (store.selectedGroup?.members.count ?? 1) > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                    Text(store.selectedGroup?.name ?? "スピーカー")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            Spacer()
            PanelToggleButton(symbol: "list.bullet", isOn: panel == .queue) {
                toggle(.queue)
            }
        }
    }

    private func toggle(_ target: NowPlayingView.Panel) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            panel = panel == target ? .none : target
        }
    }
}

struct PlayerMoreMenu: View {
    @Environment(SonosStore.self) private var store
    @Binding var panel: NowPlayingView.Panel

    var body: some View {
        Menu {
            Section("スリープタイマー") {
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes)分") { store.setSleepTimer(minutes: minutes) }
                }
                Button("オフ") { store.setSleepTimer(minutes: nil) }
            }
            Section("歌詞のタイミング") {
                Button("0.5秒 早く", systemImage: "backward") { store.lyrics.setOffset(store.lyrics.offset + 0.5) }
                Button("0.5秒 遅く", systemImage: "forward") { store.lyrics.setOffset(store.lyrics.offset - 0.5) }
                if store.lyrics.offset != 0 {
                    Button("リセット（現在 \(String(format: "%+.1f", store.lyrics.offset))秒）") { store.lyrics.setOffset(0) }
                }
            }
            Button(store.groupMuted ? "ミュート解除" : "ミュート",
                   systemImage: store.groupMuted ? "speaker.wave.2" : "speaker.slash") {
                store.toggleMute()
            }
            Button("キューを消去", systemImage: "trash", role: .destructive) { store.clearQueue() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.18), in: Circle())
        }
    }
}

// MARK: - Scrubber

struct ProgressScrubber: View {
    @Environment(SonosStore.self) private var store
    @Binding var showQuality: Bool
    @State private var scrubFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = store.duration
            let position = store.position(at: context.date)
            let shownPosition = scrubFraction.map { $0 * duration } ?? position

            VStack(spacing: 4) {
                if store.track?.isLive ?? true {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 7).frame(height: 28)
                } else {
                    CapsuleSlider(
                        value: duration > 0 ? position / duration : 0,
                        onChange: { scrubFraction = $0 },
                        onEnd: { fraction in
                            store.seek(to: fraction * duration)
                            scrubFraction = nil
                        })
                }
                ZStack {
                    HStack {
                        Text(store.track?.isLive ?? true ? "" : TimeFormat.display(shownPosition))
                        Spacer()
                        Text(store.track?.isLive ?? true ? "" : "-" + TimeFormat.display(max(0, duration - shownPosition)))
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(scrubFraction == nil ? 0.5 : 0.9))

                    centerBadge
                }
                .frame(height: 18)
            }
        }
    }

    @ViewBuilder
    private var centerBadge: some View {
        if let quality = store.quality, quality.badge != nil {
            Button { showQuality = true } label: { QualityBadge(quality: quality) }
                .buttonStyle(.plain)
        } else if store.track?.isLive == true, store.track?.kind == .radio {
            Text("LIVE")
                .font(.system(size: 10, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - Volume

struct VolumeBar: View {
    @Environment(SonosStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Button { store.toggleMute() } label: {
                Image(systemName: store.groupMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 13))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            CapsuleSlider(
                value: store.groupMuted ? 0 : Double(store.groupVolume) / 100,
                onBegin: { store.beginVolumeChange() },
                onChange: { store.setGroupVolume(Int(($0 * 100).rounded())) },
                onEnd: { store.setGroupVolume(Int(($0 * 100).rounded())) })
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .frame(width: 24)
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}
