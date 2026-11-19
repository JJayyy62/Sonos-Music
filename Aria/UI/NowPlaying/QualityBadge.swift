import SwiftUI

/// 再生画面のシークバー下に出す「ロスレス」「Dolby Atmos」バッジ
struct QualityBadge: View {
    let quality: AudioQuality

    var body: some View {
        if let badge = quality.badge {
            HStack(spacing: 4) {
                Image(systemName: badge.symbol)
                    .font(.system(size: 9, weight: .bold))
                Text(quality.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Theme.accent)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if quality.source == .appleMusicCatalog {
                    // カタログ由来の推定であることを小さく示す
                    Circle().fill(Theme.accent.opacity(0.7)).frame(width: 4, height: 4).offset(x: 1.5, y: -1.5)
                }
            }
        }
    }
}

struct QualityInfoSheet: View {
    let quality: AudioQuality?
    let deviceName: String

    var body: some View {
        NavigationStack {
            List {
                if let quality {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: quality.badge?.symbol ?? "music.note")
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quality.title).font(.title3.bold())
                                if let detail = quality.formatDetail {
                                    Text(detail).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Section("情報源") {
                        Text(quality.source.label)
                        LabeledContent("スピーカー", value: deviceName)
                    }
                    if !quality.notes.isEmpty {
                        Section {
                            ForEach(quality.notes, id: \.self) { note in
                                Text(note).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("このソースの音質情報は取得できませんでした。")
                        .foregroundStyle(.secondary)
                }
            }
            .inkBackground()
            .navigationTitle("オーディオ品質")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
