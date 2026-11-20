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
    /// 音量調節中に止めているほかのジェスチャー（スクロール・タップ・スライダーなど）
    private var suspendedRecognizers: [UIGestureRecognizer] = []
    /// 画面に触れている指を数える（すべての指が離れるまで、止めた操作を戻さない）
    private let touchWatcher = TouchWatcher()
    /// 回転は終わったが、まだ画面に指が残っているので戻すのを待っている
    private var resumeWhenTouchesEnd = false

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
        // 2本指の回転を認識した瞬間に、指の下にあるボタン・タイル・スライダーへのタッチを取り消す。
        // これで指を離したときにタップとして扱われない（1本指の操作は回転として認識されないので影響しない）
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)

        touchWatcher.onAllTouchesEnded = { [weak self] in self?.touchesDidEnd() }
        window.addGestureRecognizer(touchWatcher)

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
            // 2本指の回転を検出した時点でほかの操作を止める（音量が変わるのは engageThreshold を超えてから）
            suspendOtherGestures(except: recognizer)
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
            // 開始位置の前後 engageThreshold 度は「動かしていない」扱いにする。
            // 回して戻したとき、この範囲に入れば開始時の音量にぴったり戻る
            let effective = degrees >= 0 ? max(0, degrees - engageThreshold) : min(0, degrees + engageThreshold)
            let steps = Int((effective / degreesPerStep).rounded(.towardZero))
            let target = max(0, min(100, startVolume + steps))
            if target != store.groupVolume {
                if target == 0 || target == 100 { limit.impactOccurred() } else { selection.selectionChanged() }
                store.setGroupVolume(target)
            }
            hud.volume = target
        case .ended, .cancelled, .failed:
            // 回転は1本目の指が離れた時点で終わるので、残りの指も離れてから操作を戻す
            if touchWatcher.activeTouches == 0 {
                resumeOtherGestures()
            } else {
                resumeWhenTouchesEnd = true
            }
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

    /// 回転を検出するまではほかの操作と同時に認識させる（1本指のスクロールやタップを邪魔しない）。
    /// 検出したあとは suspendOtherGestures でほかを止める
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        suspendedRecognizers.isEmpty || other === touchWatcher
    }

    private func touchesDidEnd() {
        guard resumeWhenTouchesEnd else { return }
        resumeWhenTouchesEnd = false
        resumeOtherGestures()
    }

    // MARK: - ほかの操作を止める

    /// アプリのすべてのウインドウ（シートやフルスクリーンの再生画面を含む）のジェスチャーを一時的に無効にする。
    /// 無効にすると進行中の操作（スクロール・ボタンの押下・スライダーのドラッグ）はキャンセルされ、
    /// 指を離すまで新しい操作も始まらない
    private func suspendOtherGestures(except own: UIGestureRecognizer) {
        resumeOtherGestures()
        guard let windows = installedWindow?.windowScene?.windows else { return }
        for window in windows where window !== hudWindow {
            collect(in: window, except: own)
        }
    }

    private func collect(in view: UIView, except own: UIGestureRecognizer) {
        for recognizer in view.gestureRecognizers ?? []
        where recognizer !== own && recognizer !== touchWatcher && recognizer.isEnabled {
            recognizer.isEnabled = false
            suspendedRecognizers.append(recognizer)
        }
        for subview in view.subviews {
            collect(in: subview, except: own)
        }
    }

    private func resumeOtherGestures() {
        for recognizer in suspendedRecognizers {
            recognizer.isEnabled = true
        }
        suspendedRecognizers.removeAll()
    }
}

/// 画面に触れている指の数を数えるだけの認識器。自分では何も認識せず、ほかのタッチも邪魔しない
private final class TouchWatcher: UIGestureRecognizer {
    private(set) var activeTouches = 0
    var onAllTouchesEnded: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        activeTouches = max(0, activeTouches - touches.count)
        if activeTouches == 0 {
            state = .failed
            onAllTouchesEnded?()
        }
    }

    override func reset() {
        super.reset()
        activeTouches = 0
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
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
