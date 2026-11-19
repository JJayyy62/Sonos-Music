import SwiftUI

struct SettingsView: View {
    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    @Environment(\.dismiss) private var dismiss

    @AppStorage(RotationVolumeController.enabledKey) private var rotationEnabled = true
    @AppStorage(RotationVolumeController.sensitivityKey) private var degreesPerStep = 3.5
    @AppStorage("appleMusicSerialOverride") private var serialOverride = 0
    @State private var manualHost = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("状態", value: connectionLabel)
                    ForEach(store.allSpeakers) { speaker in
                        LabeledContent(speaker.roomName, value: speaker.host)
                    }
                    HStack {
                        TextField("IPアドレスで追加", text: $manualHost)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("追加") {
                            Task {
                                if await store.addManualHost(manualHost) { manualHost = "" }
                            }
                        }
                        .disabled(manualHost.isEmpty)
                    }
                    Button("スピーカーを再検索") { store.rediscover() }
                } header: {
                    Text("Sonos")
                } footer: {
                    Text("ソフトウェアアップデートや初期設定、音楽サービスの追加は純正のSonosアプリで行ってください。")
                }

                Section {
                    Toggle("2本指の回転で音量を変更", isOn: $rotationEnabled)
                    Picker("感度", selection: $degreesPerStep) {
                        Text("ゆっくり").tag(6.0)
                        Text("標準").tag(3.5)
                        Text("すばやく").tag(2.0)
                    }
                    .disabled(!rotationEnabled)
                } header: {
                    Text("操作")
                } footer: {
                    Text("画面のどこでも、2本指でつまみを回すように時計回りにひねると音量が上がり、反時計回りで下がります。")
                }

                Section {
                    Toggle("クロスフェード", isOn: Binding(get: { store.crossfade }, set: { store.setCrossfade($0) }))
                    if let remaining = store.sleepTimerRemaining {
                        LabeledContent("スリープタイマー", value: "残り \(TimeFormat.display(Double(remaining)))")
                        Button("スリープタイマーを解除") { store.setSleepTimer(minutes: nil) }
                    }
                } header: {
                    Text("再生（\(store.selectedGroup?.name ?? "未接続")）")
                }

                Section {
                    HStack {
                        Text("時間補正")
                        Spacer()
                        Text(String(format: "%+.1f秒", store.lyrics.offset)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { store.lyrics.offset }, set: { store.lyrics.setOffset($0) }),
                           in: -3...3, step: 0.1)
                } header: {
                    Text("歌詞")
                } footer: {
                    Text("歌詞はLRCLIB（lrclib.net）のコミュニティデータベースから取得します。歌詞が音より遅れる場合はプラスにしてください。")
                }

                Section {
                    LabeledContent("連携", value: music.isAuthorized ? "許可済み" : "未許可")
                    if !music.isAuthorized {
                        Button("Apple Musicへのアクセスを許可") {
                            Task { await music.requestAuthorization() }
                        }
                    }
                    LabeledContent("Sonosのアカウント番号", value: store.appleMusicSerialDetected.map { "自動検出: \($0)" } ?? "未検出（1を使用）")
                    Stepper(value: $serialOverride, in: 0...20) {
                        Text(serialOverride == 0 ? "手動指定: なし" : "手動指定: \(serialOverride)")
                    }
                } header: {
                    Text("Apple Music")
                } footer: {
                    Text("Apple Musicの曲を再生すると「アクセスを拒否」と表示される場合は、アカウント番号を手動で指定してみてください（多くの場合 1〜5 のいずれか）。")
                }

                Section("このアプリについて") {
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    Text("AriaはSonos社とは無関係の非公式アプリです。同じネットワーク上のSonosスピーカーをローカルで操作します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task { await store.refreshPlaybackOptions() }
        }
    }

    private var connectionLabel: String {
        switch store.connection {
        case .connected: return "接続済み（\(store.allSpeakers.count)ルーム）"
        case .searching: return "検索中…"
        case .unreachable: return "応答なし"
        }
    }
}
