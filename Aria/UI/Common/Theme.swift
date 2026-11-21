import SwiftUI

/// Aria のデザイントークン
///
/// ダークモードの Apple Music に近い黒基調。基本色はやわらかいラベンダー #B4A7F5 を一点だけ使う
enum Theme {
    /// 基本色（#B4A7F5 ラベンダー）
    static let accent = Color(red: 180 / 255, green: 167 / 255, blue: 245 / 255)
    /// 基本色の上に載せる文字色（ラベンダーの最も濃い色）
    static let onAccent = Color(red: 0.11, green: 0.09, blue: 0.22)

    /// 画面の地
    static let ink = Color(red: 0.0, green: 0.0, blue: 0.0)
    /// カード・ドック（iOS のダークモードの二次背景）
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.118)
    /// カードの上の要素・押したとき
    static let surfaceRaised = Color(red: 0.173, green: 0.173, blue: 0.18)
    /// 細い境界線
    static let hairline = Color.white.opacity(0.08)

    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.36)

    /// 小さなラベル・数字（時間や音量）用。数字は桁幅をそろえる
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold).monospacedDigit()
    }
}

extension Color {
    /// 既存コードとの互換用。中身は Theme.accent
    static let appAccent = Theme.accent
}

/// 見出しの上に置く小さなラベル（例: APPLE MUSIC）
struct IndexLabel: View {
    let index: Int?
    let text: String
    /// サービス名などを色付きで出すとき
    var tint: Color?

    var body: some View {
        // index は互換のために受け取るだけで表示しない
        Text(text.uppercased())
            .foregroundStyle(tint ?? Theme.textTertiary)
            .font(Theme.label())
            .tracking(0.6)
    }
}

/// 一覧画面（List）の背景を墨色にそろえる
struct InkListBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.ink.ignoresSafeArea())
    }
}

extension View {
    func inkBackground() -> some View { modifier(InkListBackground()) }
}
