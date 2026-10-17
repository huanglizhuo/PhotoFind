import UIKit

/// v0.8: 64-bit difference hash for "is this the same photo?" — the share
/// extension's job is to find the *original* behind a recompressed/cropped
/// WeChat image, which semantic similarity alone can't guarantee. dHash is
/// cheap (9×8 grayscale), scale/compression tolerant and stored next to the
/// embedding.
enum PerceptualHash {
    /// 9×8 grayscale, compare each pixel with its right neighbour. Drawing via
    /// UIGraphicsImageRenderer applies the image orientation, so photos from
    /// other apps hash the same as PhotoKit's 512px thumbnail.
    @MainActor
    static func dHash(_ image: UIImage) -> UInt64? {
        let width = 9, height = 8
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let small = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgImage = small.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    hash |= 1 << UInt64(y * (width - 1) + x)
                }
            }
        }
        return hash
    }

    /// Number of differing bits; ≤ ~8 is a near-duplicate for 64-bit dHash.
    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Default threshold for "same photo, recompressed or resized".
    static let nearDuplicateDistance = 8

    /// Stricter threshold for badging a result as the original rather than just
    /// a near-duplicate of the shared image.
    static let originalDistance = 4
}
