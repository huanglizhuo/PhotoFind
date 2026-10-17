import Testing
import UIKit
@testable import SemanticPhotos

/// v0.8: dHash is what makes "share a WeChat image → find the original"
/// reliable. These tests use rendered scenes, not fixed fixtures, so they
/// exercise the exact 9×8 grayscale path.
struct PerceptualHashTests {
    @MainActor
    private func scene(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 1.0, green: 0.72, blue: 0.45, alpha: 1).setFill()
            context.fill(rect)
            UIColor(red: 0.12, green: 0.28, blue: 0.36, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.62,
                                width: size.width, height: size.height * 0.38))
            UIColor(red: 1.0, green: 0.93, blue: 0.72, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.55, y: size.height * 0.18,
                                                     width: size.width * 0.22, height: size.height * 0.22))
        }
    }

    @MainActor
    private func stripes(size: CGSize, vertical: Bool) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            let step = size.width / 6
            for index in 0..<6 where index.isMultiple(of: 2) {
                if vertical {
                    context.fill(CGRect(x: CGFloat(index) * step, y: 0, width: step, height: size.height))
                } else {
                    context.fill(CGRect(x: 0, y: CGFloat(index) * step, width: size.width, height: step))
                }
            }
        }
    }

    @Test @MainActor func identicalImagesHashIdentically() {
        let image = scene(size: CGSize(width: 120, height: 100))
        let hash = PerceptualHash.dHash(image)
        #expect(hash != nil)
        #expect(hash == PerceptualHash.dHash(image))
    }

    @Test @MainActor func resizedImageStaysNearDuplicate() {
        let large = scene(size: CGSize(width: 480, height: 400))
        let small = scene(size: CGSize(width: 120, height: 100))
        let distance = PerceptualHash.distance(PerceptualHash.dHash(large) ?? 0,
                                               PerceptualHash.dHash(small) ?? 0)
        #expect(distance <= PerceptualHash.nearDuplicateDistance,
                "同一画面的缩放版本应落在近似重复阈值内，实际 \(distance)")
    }

    @Test @MainActor func differentStructuresAreNotDuplicates() {
        let vertical = stripes(size: CGSize(width: 120, height: 120), vertical: true)
        let horizontal = stripes(size: CGSize(width: 120, height: 120), vertical: false)
        let distance = PerceptualHash.distance(PerceptualHash.dHash(vertical) ?? 0,
                                               PerceptualHash.dHash(horizontal) ?? 0)
        #expect(distance > PerceptualHash.nearDuplicateDistance,
                "横竖条纹不应被判为同一张，实际 \(distance)")
    }

    @Test func distanceCountsBits() {
        #expect(PerceptualHash.distance(0, 0) == 0)
        #expect(PerceptualHash.distance(0b1010, 0b0000) == 2)
        #expect(PerceptualHash.distance(.max, 0) == 64)
    }
}
