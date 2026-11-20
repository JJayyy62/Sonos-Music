import SwiftUI

/// 再生画面のシークバー下に出す「ロスレス」「Dolby Atmos」バッジ
struct QualityBadge: View {
    let quality: AudioQuality

    var body: some View {
        if let badge = quality.badge {
            HStack(spacing: 4) {
                QualityIcon(badge: badge, size: 9)
                Text(quality.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            // 枠は付けず、アイコンと文字だけを出す。押しやすいように当たり判定だけ少し広げる
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
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
                            Group {
                                if let badge = quality.badge {
                                    QualityIcon(badge: badge, size: 22)
                                } else {
                                    Image(systemName: "music.note").font(.title2)
                                }
                            }
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

/// 品質バッジのアイコン。Dolby Atmos のときは Dolby のダブル D マーク、それ以外は SF Symbols
struct QualityIcon: View {
    let badge: AudioQuality.Badge
    /// アイコンの高さ（ポイント）
    var size: CGFloat

    var body: some View {
        if badge == .dolbyAtmos {
            DolbyMark()
                .frame(width: size * DolbyMark.aspectRatio, height: size)
                .accessibilityLabel("Dolby")
        } else {
            Image(systemName: badge.symbol)
                .font(.system(size: size, weight: .bold))
        }
    }
}

/// Dolby のダブル D マーク（向かい合う2つの「D」）。前景色で塗る
struct DolbyMark: Shape {
    /// 幅 ÷ 高さ
    static let aspectRatio: CGFloat = 1.4

    func path(in rect: CGRect) -> Path {
        let h = rect.height
        let gap = rect.width * 0.14
        let piece = (rect.width - gap) / 2
        // 上下の辺がまっすぐな部分の長さ（残りがふくらんだ曲線）
        let flat = piece * 0.5
        let k: CGFloat = 0.5523 // 楕円を4本のベジェ曲線で近似するときの係数

        var path = Path()
        // 左の「D」：左辺がまっすぐで、右側が丸くふくらむ
        let l = rect.minX, t = rect.minY
        path.move(to: CGPoint(x: l, y: t))
        path.addLine(to: CGPoint(x: l + flat, y: t))
        path.addCurve(to: CGPoint(x: l + piece, y: t + h / 2),
                      control1: CGPoint(x: l + flat + k * (piece - flat), y: t),
                      control2: CGPoint(x: l + piece, y: t + h / 2 - k * h / 2))
        path.addCurve(to: CGPoint(x: l + flat, y: t + h),
                      control1: CGPoint(x: l + piece, y: t + h / 2 + k * h / 2),
                      control2: CGPoint(x: l + flat + k * (piece - flat), y: t + h))
        path.addLine(to: CGPoint(x: l, y: t + h))
        path.closeSubpath()

        // 右の「D」：左右反転して、丸い側が左を向く
        let r = rect.maxX
        path.move(to: CGPoint(x: r, y: t))
        path.addLine(to: CGPoint(x: r - flat, y: t))
        path.addCurve(to: CGPoint(x: r - piece, y: t + h / 2),
                      control1: CGPoint(x: r - flat - k * (piece - flat), y: t),
                      control2: CGPoint(x: r - piece, y: t + h / 2 - k * h / 2))
        path.addCurve(to: CGPoint(x: r - flat, y: t + h),
                      control1: CGPoint(x: r - piece, y: t + h / 2 + k * h / 2),
                      control2: CGPoint(x: r - flat - k * (piece - flat), y: t + h))
        path.addLine(to: CGPoint(x: r, y: t + h))
        path.closeSubpath()
        return path
    }
}
