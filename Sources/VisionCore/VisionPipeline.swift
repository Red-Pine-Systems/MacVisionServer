import Foundation
import Vision
import ImageIO
import CoreGraphics

// MARK: - Timing Utilities

public func nowNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

public func msFrom(_ startNs: UInt64) -> Double {
    Double(nowNs() - startNs) / 1_000_000.0
}

// MARK: - Vision Pipeline Configuration

public struct VisionPipelineConfig {
    public let maxImageDimensionPx: Int
    public let ocrLevel: OCRLevel
    public let ocrLangCorrection: Bool
    public let ocrLangs: [String]

    public enum OCRLevel {
        case fast
        case accurate
    }

    public init(
        maxImageDimensionPx: Int = 6000,
        ocrLevel: OCRLevel = .accurate,
        ocrLangCorrection: Bool = true,
        ocrLangs: [String] = []
    ) {
        self.maxImageDimensionPx = maxImageDimensionPx
        self.ocrLevel = ocrLevel
        self.ocrLangCorrection = ocrLangCorrection
        self.ocrLangs = ocrLangs
    }
}

// MARK: - Vision Result

public struct VisionResult {
    public let width: Int
    public let height: Int
    public let faces: [FaceResult]
    public let ocrBlocks: [OCRBlock]
    public let ocrQuality: OCRQualityMetrics
    public let decodeMs: Double
    public let faceMs: Double
    public let ocrMs: Double
}

// MARK: - OCR Quality Metrics

/// OCR quality metrics for identifying pages where OCR had issues.
///
/// Recommended thresholds for flagging problematic pages:
/// - `lowConfidenceRatio > 0.1` (more than 10% of blocks are low confidence)
/// - `minConfidence < 0.5` (at least one block is very uncertain)
public struct OCRQualityMetrics: Equatable {
    /// Average confidence across all blocks (0..1). Returns 1.0 if no blocks.
    public let avgConfidence: Float
    /// Minimum confidence of any block (0..1). Returns 1.0 if no blocks.
    public let minConfidence: Float
    /// Ratio of blocks below confidence threshold (0..1)
    public let lowConfidenceRatio: Float
    /// Number of blocks below confidence threshold
    public let lowConfidenceBlockCount: Int
    /// Total number of blocks analyzed
    public let totalBlockCount: Int

    /// Default threshold for "low confidence" blocks
    public static let defaultThreshold: Float = 0.7

    /// Compute quality metrics from OCR blocks.
    ///
    /// - Parameters:
    ///   - blocks: The OCR blocks with confidence values
    ///   - threshold: Confidence threshold for "low confidence" classification (default: 0.7)
    /// - Returns: Quality metrics for the blocks
    public static func compute(from blocks: [OCRBlock], threshold: Float = defaultThreshold) -> OCRQualityMetrics {
        guard !blocks.isEmpty else {
            return OCRQualityMetrics(
                avgConfidence: 1.0,
                minConfidence: 1.0,
                lowConfidenceRatio: 0.0,
                lowConfidenceBlockCount: 0,
                totalBlockCount: 0
            )
        }

        var sum: Float = 0
        var min: Float = 1.0
        var lowCount = 0

        for block in blocks {
            let conf = block.confidence ?? 0
            sum += conf
            if conf < min { min = conf }
            if conf < threshold { lowCount += 1 }
        }

        let count = blocks.count
        return OCRQualityMetrics(
            avgConfidence: sum / Float(count),
            minConfidence: min,
            lowConfidenceRatio: Float(lowCount) / Float(count),
            lowConfidenceBlockCount: lowCount,
            totalBlockCount: count
        )
    }
}

public struct FaceResult {
    public let boundingBox: NormalizedBox
    public let confidence: Float?
}

public struct OCRBlock {
    public let text: String
    public let boundingBox: NormalizedBox
    public let confidence: Float?

    public init(text: String, boundingBox: NormalizedBox, confidence: Float?) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Bounding box in normalized coordinates (0..1) with origin at top-left.
/// To convert to pixels, multiply x/width by image width and y/height by image height.
public struct NormalizedBox: Equatable {
    /// X coordinate of top-left corner (0..1)
    public let x: Double
    /// Y coordinate of top-left corner (0..1)
    public let y: Double
    /// Width as fraction of image width (0..1)
    public let width: Double
    /// Height as fraction of image height (0..1)
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum VisionError: Error {
    case invalidImageData
    case decodeFailed
    case imageTooLarge(width: Int, height: Int, maxDimension: Int)
    case faceDetectionFailed(String)
    case ocrFailed(String)
}

public struct VisionPipeline {
    public let config: VisionPipelineConfig

    public init(config: VisionPipelineConfig) {
        self.config = config
    }

    public func process(imageData: Data) throws -> VisionResult {
        let startDecode = nowNs()

        // Decode image
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw VisionError.invalidImageData
        }

        let options: CFDictionary = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: false
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options) else {
            throw VisionError.decodeFailed
        }

        let width = cgImage.width
        let height = cgImage.height

        // Check dimensions
        if width > config.maxImageDimensionPx || height > config.maxImageDimensionPx {
            throw VisionError.imageTooLarge(width: width, height: height, maxDimension: config.maxImageDimensionPx)
        }

        let decodeMs = msFrom(startDecode)

        // Face detection
        let startFace = nowNs()
        let faces = try detectFaces(cgImage: cgImage, imageWidth: width, imageHeight: height)
        let faceMs = msFrom(startFace)

        // OCR
        let startOCR = nowNs()
        let ocrBlocks = try extractText(cgImage: cgImage, imageWidth: width, imageHeight: height)
        let ocrMs = msFrom(startOCR)

        // Compute OCR quality metrics
        let ocrQuality = OCRQualityMetrics.compute(from: ocrBlocks)

        return VisionResult(
            width: width,
            height: height,
            faces: faces,
            ocrBlocks: ocrBlocks,
            ocrQuality: ocrQuality,
            decodeMs: decodeMs,
            faceMs: faceMs,
            ocrMs: ocrMs
        )
    }

    private func detectFaces(cgImage: CGImage, imageWidth: Int, imageHeight: Int) throws -> [FaceResult] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw VisionError.faceDetectionFailed(error.localizedDescription)
        }

        guard let results = request.results else {
            return []
        }

        return results.map { observation in
            FaceResult(
                boundingBox: toNormalizedBox(observation.boundingBox),
                confidence: observation.confidence
            )
        }
    }

    private func extractText(cgImage: CGImage, imageWidth: Int, imageHeight: Int) throws -> [OCRBlock] {
        let request = VNRecognizeTextRequest()

        switch config.ocrLevel {
        case .fast:
            request.recognitionLevel = .fast
        case .accurate:
            request.recognitionLevel = .accurate
        }


        request.usesLanguageCorrection = config.ocrLangCorrection

        if !config.ocrLangs.isEmpty {
            request.recognitionLanguages = config.ocrLangs
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw VisionError.ocrFailed(error.localizedDescription)
        }

        guard let results = request.results else {
            return []
        }

        return results.compactMap { observation -> OCRBlock? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }

            return OCRBlock(
                text: candidate.string,
                boundingBox: toNormalizedBox(observation.boundingBox),
                confidence: candidate.confidence
            )
        }
    }

    /// Convert Vision's normalized bottom-left origin box to normalized top-left origin
    private func toNormalizedBox(_ rect: CGRect) -> NormalizedBox {
        NormalizedBox(
            x: rect.origin.x,
            y: 1.0 - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
