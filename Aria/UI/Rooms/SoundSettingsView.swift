import SwiftUI

/// 1台のスピーカーのサウンド設定（EQ・ラウドネス・ステレオバランス・TV音声・ハイトオーディオ）
struct SoundSettingsView: View {
    @State private var sound: SpeakerSound
    @State private var confirmReset = false

    init(speaker: SonosSpeaker) {
        _sound = State(initialValue: SpeakerSound(speaker: speaker))
    }

    var body: some View {
        Form {
            switch sound.state {
            case .loading:
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            case .failed:
                Section {
                    ContentUnavailableView("サウンド設定を読み込めませんでした", systemImage: "hifispeaker.badge.exclamationmark",
                                           description: Text("スピーカーが同じネットワークにあるか確認してください。"))
                    Button("再読み込み") { Task { await sound.load() } }
                }
            case .loaded:
                eqSection
                if sound.balance != nil { balanceSection }
                if sound.isHomeTheater { speechSection }
                if sound.heightLevel != nil { heightSection }
                Section {
                    Button("初期設定に戻す", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("設定はスピーカー本体に保存され、純正のSonosアプリにも反映されます。")
                }
            }
        }
        .inkBackground()
        .navigationTitle(sound.speaker.roomName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await sound.load() }
        .confirmationDialog("\(sound.speaker.roomName)のサウンド設定を初期設定に戻しますか？", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("初期設定に戻す", role: .destructive) { sound.reset() }
        } message: {
            Text("低音・高音・バランス・ハイトオーディオを0に、ラウドネスをオンにします。")
        }
    }

    // MARK: Sections

    private var eqSection: some View {
        Section {
            LevelSlider(title: "低音", value: $sound.bass, range: -10...10)
            LevelSlider(title: "高音", value: $sound.treble, range: -10...10)
            Toggle("ラウドネス", isOn: $sound.loudness)
        } header: {
            Text("EQ")
        } footer: {
            Text("ラウドネスは、音量を下げたときに低音と高音を補って、小さな音でも聴きやすくします。")
        }
    }

    private var balanceSection: some View {
        Section {
            BalanceSlider(value: Binding(get: { sound.balance ?? 0 }, set: { sound.balance = $0 }))
        } header: {
            Text("ステレオバランス")
        } footer: {
            Text("左右のスピーカーの音量のバランスです。ステレオペアや1台で左右を鳴らすスピーカーで使います。")
        }
    }

    private var speechSection: some View {
        Section {
            Toggle(isOn: Binding(get: { sound.speechEnhancement ?? false }, set: { sound.speechEnhancement = $0 })) {
                Label("スピーチエンハンスメント", systemImage: "waveform.and.person.filled")
            }
            if sound.nightMode != nil {
                Toggle(isOn: Binding(get: { sound.nightMode ?? false }, set: { sound.nightMode = $0 })) {
                    Label("ナイトサウンド", systemImage: "moon.fill")
                }
            }
        } header: {
            Text("TV音声")
        } footer: {
            Text("スピーチエンハンスメントは、映画やテレビのセリフを聞き取りやすくします。ナイトサウンドは、大きな音を抑えて小さな音を持ち上げます。")
        }
    }

    private var heightSection: some View {
        Section {
            LevelSlider(title: "ハイトオーディオ", value: Binding(get: { sound.heightLevel ?? 0 }, set: { sound.heightLevel = $0 }),
                        range: -10...10)
        } header: {
            Text("Dolby Atmos")
        } footer: {
            Text("上方向から聞こえる音（ハイトチャンネル）の大きさです。Dolby Atmosのコンテンツで効果があります。")
        }
    }
}

/// -10〜+10 の段階スライダー（0 で軽く触覚フィードバック）
private struct LevelSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value == 0 ? "0" : String(format: "%+d", value))
                    .font(Theme.label(14))
                    .foregroundStyle(value == 0 ? Theme.textSecondary : Theme.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
            }
            HStack(spacing: 10) {
                Text("\(range.lowerBound)").font(Theme.label(10)).foregroundStyle(Theme.textTertiary)
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                    .tint(Theme.accent)
                Text("+\(range.upperBound)").font(Theme.label(10)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: value) { _, new in new == 0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }
}

/// 左右バランス（-100〜+100）。中央付近は中央に吸い付く
private struct BalanceSlider: View {
    @Binding var value: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("L").font(Theme.label(13)).foregroundStyle(value < 0 ? Theme.accent : Theme.textTertiary)
                Spacer()
                Text(label)
                    .font(Theme.label(13))
                    .foregroundStyle(value == 0 ? Theme.textSecondary : Theme.accent)
                Spacer()
                Text("R").font(Theme.label(13)).foregroundStyle(value > 0 ? Theme.accent : Theme.textTertiary)
            }
            Slider(value: Binding(get: { Double(value) }, set: { raw in
                let rounded = Int((raw / 5).rounded()) * 5
                value = abs(rounded) <= 5 ? 0 : rounded
            }), in: -100...100)
            .tint(Theme.accent)
            if value != 0 {
                Button("中央に戻す") { value = 0 }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: value) { _, new in new == 0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ステレオバランス")
        .accessibilityValue(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(100, value + 10)
            case .decrement: value = max(-100, value - 10)
            @unknown default: break
            }
        }
    }

    private var label: String {
        if value == 0 { return "中央" }
        let (left, right) = SpeakerSound.channels(for: value)
        return value < 0 ? "左寄り（右 \(right)%）" : "右寄り（左 \(left)%）"
    }
}

/// どのスピーカーの設定をするか選ぶ画面（グループ内に複数台あるとき）
struct SoundRoomsView: View {
    let speakers: [SonosSpeaker]

    var body: some View {
        if speakers.count == 1, let speaker = speakers.first {
            SoundSettingsView(speaker: speaker)
        } else {
            List {
                Section {
                    ForEach(speakers) { speaker in
                        NavigationLink(speaker.roomName) { SoundSettingsView(speaker: speaker) }
                    }
                } footer: {
                    Text("サウンド設定はスピーカーごとに保存されます。")
                }
            }
            .inkBackground()
            .navigationTitle("サウンド")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
