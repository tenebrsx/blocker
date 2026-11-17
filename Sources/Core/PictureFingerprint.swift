import CoreGraphics
import Foundation
import Vision

/// A fingerprint of a picture from macOS's built-in feature print: a list of numbers describing how it looks. It is
/// used to recognise the same picture again (see `FeedbackLogic`). It is not the picture and cannot be turned back
/// into it. Built in, so there is nothing to download, and it takes a few tens of milliseconds.
enum PictureFingerprint {
    /// The fingerprint of `image` and the feature print revision it came from (fingerprints of different
    /// revisions are never compared), or nil if Vision could not make one.
    static func make(from image: CGImage) -> (revision: Int, vector: [Float])? {
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observation = request.results?.first, observation.elementType == .float, observation.elementCount > 0 else { return nil }
        let count = observation.elementCount
        var vector = [Float](repeating: 0, count: count)
        observation.data.withUnsafeBytes { raw in
            guard raw.count >= count * MemoryLayout<Float>.size else { return }
            for index in 0..<count { vector[index] = raw.loadUnaligned(fromByteOffset: index * 4, as: Float.self) }
        }
        return (request.revision, vector)
    }
}
