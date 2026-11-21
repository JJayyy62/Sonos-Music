import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    @Environment(\.dismiss) private var dismiss

    @AppStorage(RotationVolumeController.enabledKey) private var rotationEnabled = true
    @AppStorage(RotationVolumeController.sensitivityKey) private var degreesPerStep = 3.5
    @Environment(SpotifyService.self) private var spotify
    @State private var manualHost = ""
    @State private var showLink = false
    @State private var lyricsCacheUsage: (count: Int, bytes: Int)?
    @State private var confirmClearCache = false
    @AppStorage(LyricsTranslator.enabledKey) private var translationEnabled = true
    @AppStorage(LyricsTranslator.languageKey) private var translationLanguage = ""
    @State private var geminiKeyDraft = LyricsTranslator.apiKey ?? ""
    @State private var hasGeminiKey = LyricsTranslator.apiKey != nil

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

                if !store.allSpeakers.isEmpty {
                    Section {
                        ForEach(store.allSpeakers) { speaker in
                            NavigationLink(speaker.roomName) { SoundSettingsView(speaker: speaker) }
                        }
                    } header: {
                        Text("サウンド")
                    } footer: {
                        Text("EQ（低音・高音・ラウドネス）、ステレオバランス、スピーチエンハンスメント、ハイトオーディオをスピーカーごとに設定します。対応していない項目は表示されません。")
                    }
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
                    if store.lyrics.offset != 0 {
                        Button("0.0秒に戻す") { store.lyrics.setOffset(0) }
                    }
                } header: {
                    Text("歌詞")
                } footer: {
                    Text("歌詞は、単語ごとに光る歌詞を優先して、Better Lyrics → Karalyr → LRCLIB の順に自動で探します。どこから取れたかは歌詞の画面の一番下に表示されます。歌詞が音より遅れる場合は時間補正をプラスにしてください。")
                }

                Section {
                    Toggle("歌詞を翻訳する", isOn: $translationEnabled)
                        .onChange(of: translationEnabled) { _, _ in store.lyrics.refreshTranslation() }
                    Picker("翻訳先の言語", selection: $translationLanguage) {
                        Text("端末の言語（\(LyricsTranslator.displayName(LyricsTranslator.deviceLanguage))）").tag("")
                        ForEach(LyricsTranslator.languages, id: \.self) { language in
                            Text(LyricsTranslator.displayName(language)).tag(language)
                        }
                    }
                    .onChange(of: translationLanguage) { _, _ in store.lyrics.refreshTranslation() }
                    SecureField("Gemini API キー", text: $geminiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveGeminiKey)
                    HStack {
                        Button(hasGeminiKey ? "キーを更新" : "キーを保存", action: saveGeminiKey)
                            .disabled(geminiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                      || geminiKeyDraft == (LyricsTranslator.apiKey ?? ""))
                        Spacer()
                        if hasGeminiKey {
                            Button("キーを削除", role: .destructive) {
                                geminiKeyDraft = ""
                                saveGeminiKey()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    Link("API キーを取得（Google AI Studio）",
                         destination: URL(string: "https://aistudio.google.com/apikey")!)
                } header: {
                    Text("歌詞の翻訳")
                } footer: {
                    Text(hasGeminiKey
                         ? "時間同期の歌詞を Google の Gemini で訳し、各行の下に表示します。歌詞に翻訳が付いている曲や、翻訳先の言語で書かれた曲は訳しません。訳した結果は端末に保存し、同じ曲は通信せずに表示します。歌詞の本文が Google に送られます。"
                         : "Google AI Studio で無料の API キーを取得して入力すると、歌詞を翻訳できます。キーは端末のキーチェーンに保存されます。")
                }

                Section {
                    ForEach(StreamingService.allCases) { service in
                        NavigationLink {
                            ServiceSettingsView(service: service)
                        } label: {
                            HStack {
                                Circle().fill(service.tint).frame(width: 9, height: 9)
                                Text(service.displayName)
                                Spacer()
                                Text(status(of: service)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("リンクから再生", systemImage: "link") { showLink = true }
                } header: {
                    Text("音楽サービス")
                } footer: {
                    Text("再生はSonosに登録済みの各サービスのアカウントで行われます。サービスの追加は純正のSonosアプリで行ってください。")
                }

                Section {
                    LabeledContent("保存した歌詞", value: lyricsCacheUsage.map {
                        "\($0.count)曲・\(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file))"
                    } ?? "確認中…")
                    Button("キャッシュを削除", role: .destructive) { confirmClearCache = true }
                } header: {
                    Text("キャッシュ")
                } footer: {
                    Text("一度表示した歌詞は端末に保存し、次からは通信せずに表示します（見つかった歌詞は30日、見つからなかった結果は1日で取り直します）。削除すると、保存した歌詞と翻訳、アートワーク・曲名の日本語表記の一時データを消して、次に表示するときに取り直します。")
                }
                .task { lyricsCacheUsage = await LyricsDiskCache.shared.usage() }

                Section("このアプリについて") {
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    Text("AriaはSonos社とは無関係の非公式アプリです。同じネットワーク上のSonosスピーカーをローカルで操作します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .inkBackground()
            .alert("キャッシュを削除しますか？", isPresented: $confirmClearCache) {
                Button("キャンセル", role: .cancel) {}
                Button("削除", role: .destructive) {
                    Task {
                        await ImageLoader.shared.removeAll()
                        await TrackNameLocalizer.shared.removeAll()
                        await store.lyrics.clearAllCaches()
                        lyricsCacheUsage = await LyricsDiskCache.shared.usage()
                        store.show(message: "キャッシュを削除しました")
                    }
                }
            } message: {
                Text("保存した歌詞はすべて消え、次に表示するときにインターネットから取り直します。")
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task { await store.refreshPlaybackOptions() }
            .sheet(isPresented: $showLink) { LinkPlaySheet().presentationDetents([.medium, .large]) }
        }
    }

    private func status(of service: StreamingService) -> String {
        switch service {
        case .appleMusic: return music.isAuthorized ? "連携済み" : "未連携"
        case .spotify: return spotify.isConnected ? "ログイン済み" : (spotify.clientID.isEmpty ? "未設定" : "未ログイン")
        case .amazonMusic: return store.linkedServices.contains(.amazonMusic) ? "Sonosで検出" : "リンクで再生"
        }
    }

    private func saveGeminiKey() {
        LyricsTranslator.apiKey = geminiKeyDraft
        geminiKeyDraft = LyricsTranslator.apiKey ?? ""
        hasGeminiKey = LyricsTranslator.apiKey != nil
        store.lyrics.refreshTranslation()
    }

    private var connectionLabel: String {
        switch store.connection {
        case .connected: return "接続済み（\(store.allSpeakers.count)ルーム）"
        case .searching: return "検索中…"
        case .unreachable: return "応答なし"
        }
    }
}

/// サービスごとの設定（Sonos のアカウント番号、カタログ連携）
struct ServiceSettingsView: View {
    @Environment(SonosStore.self) private var store
    @Environment(AppleMusicService.self) private var music
    @Environment(SpotifyService.self) private var spotify
    @Environment(\.dismiss) private var dismiss
    let service: StreamingService

    @AppStorage private var serialOverride: Int

    init(service: StreamingService) {
        self.service = service
        _serialOverride = AppStorage(wrappedValue: 0, SonosStore.serialOverrideKey(service))
    }

    var body: some View {
        Form {
            catalogSection

            Section {
                LabeledContent("Sonosでの登録", value: store.linkedServices.contains(service) ? "検出済み" : "未検出")
                LabeledContent("アカウント番号", value: store.detectedSerials[service].map { "自動検出: \($0)" } ?? "未検出（1を使用）")
                Stepper(value: $serialOverride, in: 0...20) {
                    Text(serialOverride == 0 ? "手動指定: なし" : "手動指定: \(serialOverride)")
                }
            } header: {
                Text("Sonos")
            } footer: {
                Text("再生すると「アクセスを拒否」などと表示される場合は、アカウント番号を手動で指定してみてください（多くの場合 1〜5 のいずれか）。Sonosのお気に入りに\(service.displayName)の曲を1つ登録しておくと自動検出されます。")
            }
        }
        .inkBackground()
        .navigationTitle(service.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var apiStatus: String {
        switch music.apiAvailable {
        case .some(true): return music.libraryProblem == nil ? "利用可能" : "利用可能（ライブラリ不可）"
        case .some(false): return "利用不可"
        case .none: return music.isAuthorized ? "未確認" : "未連携"
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        switch service {
        case .appleMusic:
            Section {
                LabeledContent("連携", value: music.isAuthorized ? "許可済み" : "未許可")
                if !music.isAuthorized {
                    Button("Apple Musicへのアクセスを許可") { Task { await music.requestAuthorization() } }
                }
                LabeledContent("Apple Music API", value: apiStatus)
                LabeledContent("検索", value: music.usesFallbackSearch ? "簡易検索（曲・アルバム・アーティスト）" : "Apple Music API")
                if let problem = music.apiProblem ?? music.libraryProblem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
                Button("もう一度確認") {
                    Task {
                        _ = await music.libraryPlaylists()
                    }
                }
                .disabled(!music.isAuthorized)
            } header: {
                Text("検索・ライブラリ・おすすめ")
            } footer: {
                Text("ライブラリ（自分のプレイリスト・アルバム）、おすすめ、音質情報、プレイリストの検索には Apple Music API を使います。Apple Music API が使えないときも、曲・アルバム・アーティストは簡易検索（iTunes Search API）で探せます。")
            }
        case .spotify:
            Section {
                TextField("Client ID", text: Binding(get: { spotify.clientID }, set: { spotify.clientID = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                LabeledContent("Redirect URI") {
                    Text(SpotifyService.redirectURI).font(.footnote.monospaced()).textSelection(.enabled)
                }
                Button("Redirect URIをコピー", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = SpotifyService.redirectURI
                }
                if spotify.isConnected {
                    LabeledContent("ログイン中", value: spotify.userName ?? "Spotify")
                    Button("ログアウト", role: .destructive) { spotify.logout() }
                } else {
                    SpotifyLoginRow()
                        .disabled(spotify.clientID.isEmpty)
                }
            } header: {
                Text("検索・ライブラリ（Spotify Web API）")
            } footer: {
                Text("developer.spotify.com のダッシュボードでアプリを作成し、Redirect URI に上の値を登録して、表示された Client ID を入力してください。共有リンクからの再生は Client ID なしで使えますが、最初に1回だけ、純正のSonosアプリでSpotifyの曲を1つお気に入りに追加しておく必要があります（Sonos上のSpotifyアカウントを見分けるために使います）。")
            }
        case .amazonMusic:
            Section {
                Text("Amazon Musicには公開された検索APIがないため、アプリ内で検索はできません。Amazon Musicアプリの「共有 > リンクをコピー」で得たリンクから再生するか、Sonosのお気に入りに登録してください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("検索")
            }
        }
    }
}

private struct SpotifyLoginRow: View {
    @Environment(SpotifyService.self) private var spotify
    @Environment(SonosStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Button("Spotifyにログイン", systemImage: "person.crop.circle") {
            Task {
                do {
                    let url = try spotify.authorizationURL()
                    let callback = try await webAuthenticationSession.authenticate(
                        using: url, callbackURLScheme: SpotifyService.callbackScheme, preferredBrowserSession: .shared)
                    try await spotify.completeLogin(callback: callback)
                } catch {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { store.show(error) }
                }
            }
        }
    }
}
