import CoreGraphics
import Foundation

struct PhotoColor: Equatable, Sendable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    var isValid: Bool { [hue, saturation, brightness].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var isNeutral: Bool { saturation < 0.12 || brightness < 0.08 }
    var name: String {
        if isNeutral { return brightness < 0.25 ? String(localized: "墨黑") : brightness > 0.8 ? String(localized: "云白") : String(localized: "银灰") }
        switch hue {
        case ..<0.04, 0.96...: return String(localized: "珊瑚红")
        case ..<0.12: return String(localized: "暖橙")
        case ..<0.20: return String(localized: "明黄")
        case ..<0.43: return String(localized: "草木绿")
        case ..<0.55: return String(localized: "湖水青")
        case ..<0.72: return brightness < 0.5 ? String(localized: "深海蓝") : String(localized: "天空蓝")
        case ..<0.84: return String(localized: "鸢尾紫")
        default: return String(localized: "玫瑰粉")
        }
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(difference, 1 - difference)
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> PhotoColor {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == r { hue = (g - b) / delta }
            else if high == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
        }
        return PhotoColor(hue: hue, saturation: high == 0 ? 0 : delta / high, brightness: high)
    }

    /// A histogram keeps a red/blue scene red or blue instead of averaging it into purple.
    static func dominant(rgba: [UInt8]) -> PhotoColor? {
        guard !rgba.isEmpty, rgba.count.isMultiple(of: 4) else { return nil }
        var bins = Array(repeating: [PhotoColor](), count: 75)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Double(rgba[i + 3])
            guard alpha >= 128 else { continue }
            let color = rgb(min(1, Double(rgba[i]) / alpha), min(1, Double(rgba[i + 1]) / alpha),
                            min(1, Double(rgba[i + 2]) / alpha))
            let lightness = min(2, Int(color.brightness * 3))
            let index = color.isNeutral ? 72 + lightness : min(23, Int(color.hue * 24)) * 3 + lightness
            bins[index].append(color)
        }
        func neighbors(_ index: Int) -> [Int] {
            guard index < 72 else { return [] }
            let hue = index / 3, value = index % 3
            return [((hue + 23) % 24) * 3 + value, ((hue + 1) % 24) * 3 + value]
        }
        let winner = bins.indices.filter { !bins[$0].isEmpty }.max { a, b in
            func score(_ i: Int) -> Int { bins[i].count * 2 + neighbors(i).reduce(0) { $0 + bins[$1].count } }
            return score(a) < score(b)
        }
        guard let winner, !bins[winner].isEmpty else { return nil }
        var x = 0.0, y = 0.0, saturation = 0.0, brightness = 0.0, weight = 0.0
        for index in [winner] + neighbors(winner) {
            let w = index == winner ? 1.0 : 0.5
            for color in bins[index] {
                x += cos(color.hue * 2 * .pi) * w
                y += sin(color.hue * 2 * .pi) * w
                saturation += color.saturation * w
                brightness += color.brightness * w
                weight += w
            }
        }
        return PhotoColor(hue: (atan2(y, x) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1),
                          saturation: saturation / weight, brightness: brightness / weight)
    }

    @concurrent
    static func extract(_ image: CGImage) async throws -> PhotoColor? {
        try Task.checkCancellation()
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 128, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                        CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        try Task.checkCancellation()
        return drawn ? dominant(rgba: bytes) : nil
    }
}

struct ColoredPhoto: Identifiable, Equatable, Sendable {
    let id: String
    let modified: Date?
    let color: PhotoColor

    static func sameVersion(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) <= 0.001
        default: return false
        }
    }

    /// Start at warm orange and travel through rose, violet, blue, green and yellow.
    var huePosition: Double { (1 + 1.0 / 12 - color.hue).truncatingRemainder(dividingBy: 1) }

    @concurrent
    static func arranged(_ photos: [ColoredPhoto]) async throws -> [ColoredPhoto] {
        try Task.checkCancellation()
        let result = photos.sorted {
            if $0.color.isNeutral != $1.color.isNeutral { return !$0.color.isNeutral }
            if !$0.color.isNeutral {
                let a = Int($0.huePosition * 36), b = Int($1.huePosition * 36)
                if a != b { return a < b }
            }
            if $0.color.brightness != $1.color.brightness { return $0.color.brightness > $1.color.brightness }
            if $0.color.hue != $1.color.hue { return $0.huePosition < $1.huePosition }
            return $0.id < $1.id
        }
        try Task.checkCancellation()
        return result
    }

    static func nearest(to hue: Double, in photos: [ColoredPhoto]) -> ColoredPhoto? {
        photos.filter { !$0.color.isNeutral }.min {
            PhotoColor.hueDistance($0.color.hue, hue) < PhotoColor.hueDistance($1.color.hue, hue)
        }
    }
}

/// Exact circular hue lookup; built once per palette, then O(log n) per drag event.
struct HueLookup: Sendable {
    private let colors: [(photo: ColoredPhoto, order: Int)]

    init(_ photos: [ColoredPhoto]) {
        var seen = Set<Double>()
        colors = photos.enumerated().filter { !$0.element.color.isNeutral && seen.insert($0.element.color.hue).inserted }
            .map { (photo: $0.element, order: $0.offset) }
            .sorted { $0.photo.color.hue < $1.photo.color.hue }
    }

    func nearest(to value: Double) -> ColoredPhoto? {
        guard !colors.isEmpty, value.isFinite else { return nil }
        let hue = (0..<1).contains(value) ? value : (value.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        var low = 0, high = colors.count
        while low < high {
            let mid = (low + high) / 2
            if colors[mid].photo.color.hue < hue { low = mid + 1 } else { high = mid }
        }
        let after = colors[low % colors.count]
        let before = colors[(low + colors.count - 1) % colors.count]
        let a = PhotoColor.hueDistance(after.photo.color.hue, hue)
        let b = PhotoColor.hueDistance(before.photo.color.hue, hue)
        return a < b || (a == b && after.order < before.order) ? after.photo : before.photo
    }
}

struct ColorPalette: Sendable {
    let chromatic: [ColoredPhoto]
    let neutral: [ColoredPhoto]
    let chromaticIDs: [String]
    let neutralIDs: [String]
    let lookup: HueLookup

    @concurrent static func prepare(_ photos: [ColoredPhoto]) async throws -> ColorPalette {
        let sorted = try await ColoredPhoto.arranged(photos)
        let chromatic = sorted.filter { !$0.color.isNeutral }
        let neutral = sorted.filter { $0.color.isNeutral }
        return ColorPalette(chromatic: chromatic, neutral: neutral,
                            chromaticIDs: chromatic.map(\.id), neutralIDs: neutral.map(\.id),
                            lookup: HueLookup(chromatic))
    }
}
