import SwiftUI

struct QueuePanel: View {
    @Environment(SonosStore.self) private var store
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ModeChip(symbol: "shuffle", isOn: store.playMode.shuffle) { store.toggleShuffle() }
                ModeChip(symbol: store.playMode.repeatMode == .one ? "repeat.1" : "repeat",
                         isOn: store.playMode.repeatMode != .off) { store.cycleRepeat() }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("次に再生").font(.headline)
                    if !store.isPlayingQueue, store.track != nil {
                        Text("現在はキュー以外のソースを再生中です")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                if !store.queue.isEmpty {
                    Button(editing ? "完了" : "編集") {
                        withAnimation { editing.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                }
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
                            .onTapGesture { if !editing { store.playQueueItem(at: index) } }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowSeparatorTint(.white.opacity(0.12))
                        }
                        .onDelete { store.removeQueueItems(at: $0) }
                        .onMove { store.moveQueueItem(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, .constant(editing ? .active : .inactive))
                    .onAppear { scrollToCurrent(proxy) }
                    .onChange(of: store.currentTrackNumber) { _, _ in
                        withAnimation { scrollToCurrent(proxy) }
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .task { await store.refreshQueue() }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        let index = store.currentTrackNumber - 1
        guard store.isPlayingQueue, store.queue.indices.contains(index) else { return }
        proxy.scrollTo(store.queue[index].id, anchor: .top)
    }
}

private struct QueueRow: View {
    let item: DIDLItem
    let host: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let isPast: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.artworkURL(host: host), cornerRadius: 5)
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
                Text(item.title).lineLimit(1)
                Text(item.artist ?? "")
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
        }
        .foregroundStyle(.white)
        .opacity(isPast ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}
