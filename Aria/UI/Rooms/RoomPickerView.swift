import SwiftUI

/// スピーカー選択・グループ編集
struct RoomPickerView: View {
    @Environment(SonosStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let group = store.selectedGroup {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                                    .foregroundStyle(Color.appAccent)
                                Text(group.name).font(.headline)
                                Spacer()
                                Text("\(store.groupVolume)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(store.groupVolume) },
                                set: { store.setGroupVolume(Int($0.rounded())) }),
                                   in: 0...100,
                                   onEditingChanged: { editing in
                                if editing { store.beginVolumeChange() }
                            })
                            .tint(Color.appAccent)
                        }
                        .padding(.vertical, 4)
                        NavigationLink {
                            SoundRoomsView(speakers: group.members)
                        } label: {
                            Label("サウンド設定", systemImage: "slider.vertical.3")
                        }
                    } header: {
                        Text("再生中のグループ")
                    }

                    Section {
                        ForEach(store.allSpeakers) { speaker in
                            RoomRow(speaker: speaker, group: group)
                        }
                    } header: {
                        Text("ルーム")
                    } footer: {
                        Text("チェックを付けたルームで同じ音楽を再生します。")
                    }
                }

                let others = store.groups.filter { $0.coordinator.uuid != store.selectedGroup?.coordinator.uuid }
                if !others.isEmpty {
                    Section("ほかのグループを操作") {
                        ForEach(others) { group in
                            Button {
                                store.select(group: group)
                            } label: {
                                Label(group.name, systemImage: group.members.count > 1 ? "hifispeaker.2" : "hifispeaker")
                            }
                        }
                    }
                }
            }
            .inkBackground()
            .navigationTitle("スピーカー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    await store.refreshMemberVolumes()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}

private struct RoomRow: View {
    @Environment(SonosStore.self) private var store
    let speaker: SonosSpeaker
    let group: SonosGroup

    private var isMember: Bool { group.contains(speaker.uuid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(speaker.roomName)
                if speaker.uuid == group.coordinator.uuid, group.members.count > 1 {
                    Text("コーディネーター")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if isMember {
                        store.remove(speaker)
                    } else {
                        store.add(speaker)
                    }
                } label: {
                    Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isMember ? Color.appAccent : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isMember && group.members.count == 1)
            }
            if isMember, group.members.count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(store.memberVolumes[speaker.uuid] ?? 0) },
                        set: { store.setMemberVolume(speaker, Int($0.rounded())) }),
                           in: 0...100)
                    .tint(.secondary)
                    Text("\(store.memberVolumes[speaker.uuid] ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// ツールバー用の現在のスピーカー表示
struct RoomChip: View {
    @Environment(SonosStore.self) private var store
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: (store.selectedGroup?.members.count ?? 1) > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                Text(store.selectedGroup?.name ?? "未接続")
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
        }
    }
}
