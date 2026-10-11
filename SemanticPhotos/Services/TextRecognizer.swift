import ImageIO
import UIKit
import Vision

/// On-device text recognition for the second indexing pass (F4.12).
/// Chinese is only available at the accurate level (fast is Latin-only).
enum TextRecognizer {
    static func recognize(_ image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        let lines = try await request.perform(on: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
