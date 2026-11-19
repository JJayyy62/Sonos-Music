import SwiftUI
import UIKit

extension Color {
    /// Apple Music風のアクセントカラー
    static let appAccent = Color(red: 0.98, green: 0.17, blue: 0.29)
}

// MARK: - Image loading

actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 300
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = inflight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

// MARK: - Artwork view

struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var placeholderSymbol = "music.note"

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    GeometryReader { geometry in
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.36), Color(white: 0.24)], startPoint: .top, endPoint: .bottom)
                            Image(systemName: placeholderSymbol)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geometry.size.width * 0.34)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                let loaded = await ImageLoader.shared.image(for: url)
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
    }
}

// MARK: - Palette for the animated background

struct ArtworkPalette: Equatable {
    var colors: [Color]

    static let fallback = ArtworkPalette(colors: [
        Color(white: 0.22), Color(white: 0.18), Color(white: 0.24),
        Color(white: 0.16), Color(white: 0.20), Color(white: 0.14),
        Color(white: 0.12), Color(white: 0.17), Color(white: 0.11),
    ])

    static func load(from url: URL?) async -> ArtworkPalette {
        guard let url, let image = await ImageLoader.shared.image(for: url) else { return .fallback }
        return extract(from: image) ?? .fallback
    }

    /// 画像を3×3ブロックの平均色に縮約して、メッシュグラデーションの9色にする
    static func extract(from image: UIImage) -> ArtworkPalette? {
        guard let cgImage = image.cgImage else { return nil }
        let size = 24
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        let block = size / 3
        var colors: [Color] = []
        for row in 0..<3 {
            for column in 0..<3 {
                var r = 0.0, g = 0.0, b = 0.0
                for y in (row * block)..<((row + 1) * block) {
                    for x in (column * block)..<((column + 1) * block) {
                        let i = (y * size + x) * 4
                        r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2])
                    }
                }
                let count = Double(block * block) * 255
                colors.append(adjusted(red: r / count, green: g / count, blue: b / count))
            }
        }
        return ArtworkPalette(colors: colors)
    }

    /// 白い文字が読めるように明るさを抑え、少し彩度を上げる
    private static func adjusted(red: Double, green: Double, blue: Double) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let s = min(1, saturation * 1.2)
        let v = min(0.62, max(0.16, brightness * 0.85))
        return Color(hue: hue, saturation: s, brightness: v)
    }
}

struct AnimatedMeshBackground: View {
    let palette: ArtworkPalette
    var animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))
            MeshGradient(width: 3, height: 3, points: Self.points(t), colors: palette.colors)
        }
        .overlay(Color.black.opacity(0.22))
        .animation(.easeInOut(duration: 1.2), value: palette)
    }

    private static func points(_ t: Float) -> [SIMD2<Float>] {
        let a = sin(t * 0.35) * 0.14
        let b = cos(t * 0.27) * 0.14
        let c = sin(t * 0.21 + 1.3) * 0.12
        let d = cos(t * 0.31 + 0.7) * 0.10
        return [
            SIMD2(0, 0), SIMD2(0.5 + a, 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + b), SIMD2(0.5 + c, 0.5 + d), SIMD2(1, 0.5 - c),
            SIMD2(0, 1), SIMD2(0.5 - b, 1), SIMD2(1, 1),
        ]
    }
}
