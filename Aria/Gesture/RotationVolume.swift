import SwiftUI
import UIKit

/// 画面のどこでも、2本指でつまみを回すように回転させると音量が変わる。
/// ウインドウに UIRotationGestureRecognizer を付けるので、シートやフルスクリーン表示の上でも動作する。
@MainActor
final class RotationVolumeController: NSObject, UIGestureRecognizerDelegate {
    static let shared = RotationVolumeController()

    nonisolated static let sensitivityKey = "rotationDegreesPerStep"
    nonisolated static let enabledKey = "rotationVolumeEnabled"

    private weak var installedWindow: UIWindow?
    private var hudWindow: UIWindow?
    private let hud = VolumeHUDModel()
    private let selection = UISelectionFeedbackGenerator()
    private let limit = UIImpactFeedbackGenerator(style: .rigid)

    private var startVolume = 0
    private var engaged = false
    private var hideTask: Task<Void, Never>?

    /// 回転開始とみなす角度（ピンチ等の誤動作防止）
    private let engageThreshold = 8.0

    private var degreesPerStep: Double {
        let value = UserDefaults.standard.double(forKey: Self.sensitivityKey)
        return value > 0 ? value : 3.5
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func install(on window: UIWindow) {
        guard installedWindow !== window else { return }
        installedWindow = window

        let recognizer = UIRotationGestureRecognizer(target: self, action: #selector(handle(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)

        if let scene = window.windowScene {
            let overlay = PassthroughWindow(windowScene: scene)
            overlay.windowLevel = .alert + 1
            overlay.backgroundColor = .clear
            overlay.isUserInteractionEnabled = false
            let host = UIHostingController(rootView: VolumeHUDView(model: hud))
            host.view.backgroundColor = .clear
            overlay.rootViewController = host
            overlay.isHidden = false
            hudWindow = overlay
        }
    }

    @objc private func handle(_ recognizer: UIRotationGestureRecognizer) {
        let store = SonosStore.shared
        guard isEnabled, let group = store.selectedGroup else { return }

        switch recognizer.state {
        case .began:
            engaged = false
            startVolume = store.groupVolume
        case .changed:
            let degrees = Double(recognizer.rotation) * 180 / .pi
            if !engaged {
                guard abs(degrees) >= engageThreshold else { return }
                engaged = true
                startVolume = store.groupVolume
                store.beginVolumeChange()
                selection.prepare()
                hideTask?.cancel()
                hud.roomName = group.name
                hud.volume = startVolume
                hud.visible = true
            }
            let effective = degrees - (degrees > 0 ? engageThreshold : -engageThreshold)
            let steps = Int((effective / degreesPerStep).rounded(.towardZero))
            let target = max(0, min(100, startVolume + steps))
            if target != store.groupVolume {
                if target == 0 || target == 100 { limit.impactOccurred() } else { selection.selectionChanged() }
                store.setGroupVolume(target)
            }
            hud.volume = target
        case .ended, .cancelled, .failed:
            guard engaged else { return }
            engaged = false
            hideTask?.cancel()
            hideTask = Task { [hud] in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                hud.visible = false
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

@Observable @MainActor
final class VolumeHUDModel {
    var visible = false
    var volume = 0
    var roomName = ""
}

struct VolumeHUDView: View {
    let model: VolumeHUDModel

    var body: some View {
        ZStack {
            if model.visible {
                VolumeKnob(volume: model.volume, roomName: model.roomName)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.visible)
        .allowsHitTesting(false)
    }
}

private struct VolumeKnob: View {
    let volume: Int
    let roomName: String

    private var fraction: Double { Double(volume) / 100 }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(18)
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(18)
                // つまみの指標
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 4, height: 14)
                    .offset(y: -50)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
                VStack(spacing: 2) {
                    Text("\(volume)")
                        .font(.system(size: 44, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(volume)))
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.\(min(3, volume / 34 + 1)).fill")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 190, height: 190)
            .animation(.snappy(duration: 0.15), value: volume)

            Text(roomName)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}

/// SwiftUI からウインドウを取得してジェスチャーを取り付ける
struct RotationGestureInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: WindowObserverView, context: Context) {}

    final class WindowObserverView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { RotationVolumeController.shared.install(on: window) }
        }
    }
}
