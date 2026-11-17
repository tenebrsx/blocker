import CoreGraphics
@preconcurrency import CoreML
import Foundation

/// Runs the NudeNet body-part model (`NudeNet.mlpackage`, made by `scripts/convert_nudenet_model.py`) on a piece
/// of the screen, to say what was in it. Optional: without the model file everything else works and the Block
/// Log simply has no body-part lines.
///
/// It is only called after a block (or a near miss), never on every scan, so it costs no battery. The picture is
/// looked at in memory and is never saved.
final class BodyPartDetector {
    static let shared = BodyPartDetector()

    private let queue = DispatchQueue(label: "com.wordblocker.bodyparts")
    private var model: MLModel?
    private var modelStamp: Date?

    private init() {}

    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WordBlocker", isDirectory: true)
    }

    /// Whether the model file is there.
    var isInstalled: Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: supportDirectory.appendingPathComponent("NudeNet.mlpackage").path)
            || manager.fileExists(atPath: supportDirectory.appendingPathComponent("NudeNet.mlmodelc").path)
    }

    /// Loads `NudeNet.mlmodelc`, compiling it from `NudeNet.mlpackage` first when needed.
    private func loadModelIfNeeded() async -> MLModel? {
        let package = supportDirectory.appendingPathComponent("NudeNet.mlpackage")
        let compiled = supportDirectory.appendingPathComponent("NudeNet.mlmodelc")
        let manager = FileManager.default

        func modified(_ url: URL) -> Date? {
            (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        let packageDate = modified(package)
        let compiledDate = modified(compiled)
        if let model = model, modelStamp == (compiledDate ?? packageDate) { return model }

        do {
            if let packageDate = packageDate, compiledDate == nil || compiledDate! < packageDate {
                let temporary = try await MLModel.compileModel(at: package)
                try? manager.removeItem(at: compiled)
                try manager.moveItem(at: temporary, to: compiled)
            }
            guard manager.fileExists(atPath: compiled.path) else { return nil }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly      // a few runs a day: not worth waking the Neural Engine
            let loaded = try MLModel(contentsOf: compiled, configuration: configuration)
            model = loaded
            modelStamp = modified(compiled)
            return loaded
        } catch {
            print("[BodyPartDetector] Could not load the model: \(error)")
            return nil
        }
    }

    /// The body parts in `image`, or nil when the model is not installed or could not run. An empty list means
    /// the detector looked and found nothing.
    func detect(in image: CGImage) async -> [BodyPartLogic.Detection]? {
        guard let model = await loadModelIfNeeded(),
              let square = BodyPartDetector.letterboxed(image),
              let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let input = try? MLFeatureValue(cgImage: square, constraint: constraint, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input]) else { return nil }

        // One run at a time: the model object is shared.
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let output = try? model.prediction(from: provider),
                      let array = output.featureValue(for: "detections")?.multiArrayValue,
                      array.shape.count == 3, array.shape[1].intValue == 4 + BodyPartLogic.labels.count else {
                    continuation.resume(returning: nil)
                    return
                }
                let anchors = array.shape[2].intValue
                continuation.resume(returning: BodyPartLogic.decode(BodyPartDetector.floats(array), anchors: anchors))
            }
        }
    }

    /// The model's output as a flat list of floats, row after row.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        if array.dataType == .float32 {
            let contiguous = array.strides.last?.intValue == 1
                && (array.shape.count < 2 || array.strides[array.shape.count - 2].intValue == array.shape[array.shape.count - 1].intValue)
            if contiguous {
                let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
                return Array(UnsafeBufferPointer(start: pointer, count: count))
            }
        }
        // Any other layout: read it value by value.
        var result = [Float](repeating: 0, count: count)
        let rows = array.shape[1].intValue, columns = array.shape[2].intValue
        for row in 0..<rows {
            for column in 0..<columns {
                result[row * columns + column] = array[[0, NSNumber(value: row), NSNumber(value: column)]].floatValue
            }
        }
        return result
    }

    /// The picture on a black square, top-left, scaled to the model's size: the way the model was trained
    /// (the picture keeps its shape; the empty strip is at the bottom or the right).
    static func letterboxed(_ image: CGImage) -> CGImage? {
        let size = BodyPartLogic.modelSize
        guard image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .high

        let scale = Double(size) / Double(max(image.width, image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        // Core Graphics counts from the bottom, so "top-left" is the top edge of the square.
        context.draw(image, in: CGRect(x: 0, y: Double(size) - height, width: width, height: height))
        return context.makeImage()
    }
}
