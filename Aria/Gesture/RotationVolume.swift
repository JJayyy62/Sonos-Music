import SwiftUI
import UIKit

/// 画面のどこでも、2本指でつまみを回すように回転させると音量が変わる（純正 Sonos アプリの「Virtual Volume Knob」と同じ操作）。
/// 2本指で回し始めたら、1本指を離しても、残った1本の指で画面中央のつまみの周りをなぞって回し続けられる。
/// ウインドウに付けるので、シートやフルスクリーン表示の上でも動作する。
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
    private var resumeTask: Task<Void, Never>?

    /// 回転開始とみなす角度（ピンチ等の誤動作防止）
    private let engageThreshold = 8.0

    /// 純正 Sonos アプリと同じく、2.5° 回すごとに音量が 1 変わる（画面録画をコマ送りして測った値）
    nonisolated static let standardDegreesPerStep = 2.5

    private var degreesPerStep: Double {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: Self.sensitivityKey)
        // 以前の「標準」（3.5°）は、Sonos アプリに合わせた新しい標準に置き換える
        if value == 3.5 {
            defaults.set(Self.standardDegreesPerStep, forKey: Self.sensitivityKey)
            return Self.standardDegreesPerStep
        }
        return value > 0 ? value : Self.standardDegreesPerStep
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func install(on window: UIWindow) {
        guard installedWindow !== window else { return }
        installedWindow = window

        let recognizer = KnobRotationGestureRecognizer(target: self, action: #selector(handle(_:)))
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
        #if DEBUG
        // 開発用：起動引数 -AriaVolumeHUDPreview <音量> で、つまみの表示だけを出す（スピーカーの音量は変えない）
        if UserDefaults.standard.object(forKey: "AriaVolumeHUDPreview") != nil {
            hud.roomName = "Sonos Beam"
            hud.volume = UserDefaults.standard.integer(forKey: "AriaVolumeHUDPreview")
            hud.visible = true
        }
        #endif
    }

    @objc private func handle(_ recognizer: KnobRotationGestureRecognizer) {
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
            // 回転はすべての指が離れた時点で終わる。念のため、ほかの指が残っていれば離れてから操作を戻す
            if touchWatcher.activeTouches == 0 {
                scheduleResume()
            } else {
                resumeWhenTouchesEnd = true
            }
            guard engaged else { return }
            engaged = false
            hideTask?.cancel()
            hideTask = Task { [hud] in
                // 純正 Sonos アプリと同じく、指を離したらすぐ消す
                try? await Task.sleep(for: .milliseconds(100))
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
        scheduleResume()
    }

    /// 止めた操作を少し遅れて戻す。
    /// 指が離れた瞬間に戻すと、同じ「指を離した」通知をボタンなどが受け取り、最初に触れていた指のタップとして
    /// 実行されてしまう（2本指で回したのに、下のボタンが押される）。通知が済んでから戻す
    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.resumeOtherGestures()
        }
    }

    // MARK: - ほかの操作を止める

    /// アプリのすべてのウインドウ（シートやフルスクリーンの再生画面を含む）のジェスチャーを一時的に無効にする。
    /// 無効にすると進行中の操作（スクロール・ボタンの押下・スライダーのドラッグ）はキャンセルされ、
    /// 指を離すまで新しい操作も始まらない
    private func suspendOtherGestures(except own: UIGestureRecognizer) {
        resumeTask?.cancel()
        resumeOtherGestures()
        guard let windows = installedWindow?.windowScene?.windows else { return }
        for window in windows where window !== hudWindow {
            collect(in: window, except: own)
        }
        // SwiftUI のボタンは、認識器を止めても指を離したときに押されてしまう。
        // アプリ全体を「使用不可」にして、ボタンが動かないようにする（RootView の .disabled を参照）
        KnobState.shared.isTurning = true
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
        KnobState.shared.isTurning = false
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

/// つまみを回す操作を認識する。
/// - 2本指：2本の指を結ぶ線の向きの変化を回転量にする
/// - 2本指で回し始めたあとに1本を離した場合：残った指の、つまみの中心から見た向きの変化を回転量にする
/// すべての指が離れたら終わる。`rotation` は時計回りがプラス（ラジアン）
final class KnobRotationGestureRecognizer: UIGestureRecognizer {
    private(set) var rotation: CGFloat = 0
    /// 1本指のとき、つまみの中心にこれより近い位置では向きが大きくぶれるので回転に数えない
    private let minimumRadius: CGFloat = 40

    private var tracked: [UITouch] = []
    private var lastAngle: CGFloat?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches where tracked.count < 2 { tracked.append(touch) }
        // 2本そろったら、その向きを起点にする（回している途中で指を置き直した場合も同じ）
        if tracked.count == 2 {
            lastAngle = currentAngle()
            // 2本目の指が触れた瞬間に認識を始める。これで、先に触れていた1本目の指の操作（ボタン・タイルの押下や
            // スクロール）がその場で取り消され、指を離したときにタップとして実行されない。
            // 音量が変わるのは、つまみを engageThreshold 以上回してから
            if state == .possible { state = .began }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let angle = currentAngle() else { return }
        if let lastAngle { rotation += Self.wrapped(angle - lastAngle) }
        lastAngle = angle
        switch state {
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, finalState: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, finalState: .cancelled)
    }

    private func lift(_ touches: Set<UITouch>, finalState: UIGestureRecognizer.State) {
        tracked.removeAll { touches.contains($0) }
        if state == .possible {
            // 回し始める前に指が離れた：つまみの操作ではない
            if tracked.count < 2 { state = .failed }
            return
        }
        if tracked.isEmpty {
            state = finalState
        } else {
            // 1本だけ残った：その指の向きを起点にして、1本指で回し続ける
            lastAngle = currentAngle()
        }
    }

    override func reset() {
        super.reset()
        tracked.removeAll()
        rotation = 0
        lastAngle = nil
    }

    private func currentAngle() -> CGFloat? {
        guard let view else { return nil }
        if tracked.count == 2 {
            let a = tracked[0].location(in: view), b = tracked[1].location(in: view)
            return atan2(b.y - a.y, b.x - a.x)
        }
        guard tracked.count == 1, state == .began || state == .changed else { return nil }
        let point = tracked[0].location(in: view)
        // 画面に出しているつまみの中心（VolumeHUDView と同じ位置）
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.height * VolumeHUDModel.centerFraction)
        let dx = point.x - center.x, dy = point.y - center.y
        guard dx * dx + dy * dy >= minimumRadius * minimumRadius else { return nil }
        return atan2(dy, dx)
    }

    /// 角度の差を -π〜π に収める（角度が一周をまたいだときに跳ばないように）
    private static func wrapped(_ angle: CGFloat) -> CGFloat {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}

private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// つまみを回している間（指を離して少し経つまで）か。この間はアプリ全体のボタンを使用不可にする
@Observable @MainActor
final class KnobState {
    static let shared = KnobState()
    var isTurning = false
}

@Observable @MainActor
final class VolumeHUDModel {
    /// つまみの中心の高さ（画面の上からの割合）。純正 Sonos アプリと同じく、画面の中央より少し上
    nonisolated static let centerFraction: CGFloat = 0.466

    var visible = false
    var volume = 0
    var roomName = ""
}

/// 回している間に出す表示。純正 Sonos アプリの「Virtual Volume Knob」と同じく、
/// 画面全体を暗くして、その上に白い目盛りの輪・ルーム名・音量の数字だけを出す
struct VolumeHUDView: View {
    let model: VolumeHUDModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if model.visible {
                    Color.black.opacity(0.72)
                        .transition(.opacity)
                    VolumeKnob(volume: model.volume, roomName: model.roomName,
                               diameter: geometry.size.width * 0.8)
                        .position(x: geometry.size.width / 2,
                                  y: geometry.size.height * VolumeHUDModel.centerFraction)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.15), value: model.visible)
        .allowsHitTesting(false)
    }
}

/// 白い目盛りが並んだ輪。音量に合わせて輪そのものが回る（音量 1 につき 2.5°。つまみを回した量と同じ）。
/// 輪の上にルーム名、中央に音量の数字を出す
private struct VolumeKnob: View {
    let volume: Int
    let roomName: String
    let diameter: CGFloat

    private static let tickCount = 36

    var body: some View {
        let tickLength = diameter * 0.058
        ZStack {
            ForEach(0..<Self.tickCount, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: tickLength)
                    .offset(y: -(diameter - tickLength) / 2)
                    .rotationEffect(.degrees(Double(index) * 360 / Double(Self.tickCount)))
            }
            // 純正アプリと同じ目盛りの位置にそろえる（音量 9 のとき、真上に目盛りが来る）
            .rotationEffect(.degrees(Double(volume - 9) * RotationVolumeController.standardDegreesPerStep))

            Text("\(volume)")
                .font(.system(size: 40, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(volume)))

            Text(roomName)
                .font(.system(size: 16))
                .lineLimit(1)
                .offset(y: -diameter / 2 - 17)
        }
        .frame(width: diameter, height: diameter)
        .foregroundStyle(.white)
        .animation(.snappy(duration: 0.12), value: volume)
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
