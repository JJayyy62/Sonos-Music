import SwiftUI

/// Apple Music風の、触ると太くなるカプセル型スライダー（相対ドラッグ）
struct CapsuleSlider: View {
    /// 0...1
    var value: Double
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }
    var onEnd: (Double) -> Void = { _ in }

    @State private var dragValue: Double?
    @State private var startValue = 0.0

    var body: some View {
        GeometryReader { geometry in
            let shown = min(1, max(0, dragValue ?? value))
            let editing = dragValue != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(editing ? 0.95 : 0.7))
                    .frame(width: shown * geometry.size.width)
            }
            .frame(height: editing ? 12 : 7)
            .clipShape(Capsule())
            .scaleEffect(x: editing ? 1.025 : 1, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragValue == nil {
                            startValue = value
                            onBegin()
                        }
                        let width = max(geometry.size.width, 1)
                        let next = min(1, max(0, startValue + gesture.translation.width / width))
                        dragValue = next
                        onChange(next)
                    }
                    .onEnded { _ in
                        onEnd(dragValue ?? value)
                        dragValue = nil
                    }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: editing)
        }
        .frame(height: 28)
    }
}

/// 押すと円形のハイライトが出る再生ボタン
struct TransportButtonStyle: ButtonStyle {
    var size: CGFloat = 76

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : 0)))
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// 歌詞・キューボタンなどのトグル
struct PanelToggleButton: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.75) : Color.white.opacity(0.75))
                .frame(width: 40, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(isOn ? 0.85 : 0)))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

/// シャッフル / リピートのチップ
struct ModeChip: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.8) : Color.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(isOn ? 0.85 : 0.14)))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

/// アルバム画面の「再生」「シャッフル」ボタン
struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(Color.appAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 24)
            .padding(.top, 8)
    }
}

struct ToastOverlay: ViewModifier {
    @Environment(SonosStore.self) private var store

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = store.toast {
                ToastView(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.toast)
    }
}

extension View {
    func sonosToast() -> some View { modifier(ToastOverlay()) }
}

/// トラックの行（ライブラリ・検索・アルバム共通）
struct TrackRow: View {
    let title: String
    var subtitle: String?
    var artworkURL: URL?
    var leadingNumber: Int?
    var trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            if let leadingNumber {
                Text("\(leadingNumber)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .center)
            } else {
                ArtworkView(url: artworkURL, cornerRadius: 5)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
