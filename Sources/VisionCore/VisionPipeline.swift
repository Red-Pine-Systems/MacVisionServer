import Foundation
import Vision
import ImageIO
import CoreGraphics
import DataDetection
import NaturalLanguage

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

/// A single word with its tight bounding box, plus the index of the containing OCR line block.
public struct OCRWord {
    public let text: String
    public let boundingBox: NormalizedBox
    public let confidence: Float?
    /// Index of the parent line block in the same result's `ocrBlocks` array.
    public let blockIndex: Int

    public init(text: String, boundingBox: NormalizedBox, confidence: Float?, blockIndex: Int) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.blockIndex = blockIndex
    }
}

/// Result of word-level OCR extraction.
public struct OCRWordsResult {
    public let width: Int
    public let height: Int
    public let blocks: [OCRBlock]
    public let words: [OCRWord]
    public let ocrQuality: OCRQualityMetrics
    public let decodeMs: Double
    public let ocrMs: Double
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
    /// The document-structure layout API (RecognizeDocumentsRequest) requires
    /// macOS 26; the running OS is older.
    case layoutUnavailable
    case layoutFailed(String)
}

// MARK: - Layout (document structure) types

/// A pixel-space axis-aligned box, origin top-left, matching the parsing
/// pipeline's `/layout` wire contract (`piko_layout/wire.py`).
public struct PixelBox: Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

/// One layout region = one structural element (paragraph / table / list item),
/// mapped to a canonical `piko_layout` ElementLabel value.
public struct LayoutRegion {
    public let label: String        // canonical ElementLabel.value (snake_case)
    public let bboxPx: PixelBox     // pixels, top-left origin
    public let confidence: Float?
    public let position: Int        // reading order
    /// Vision's transcribed text for this region (empty for tables, whose
    /// content GLM transcribes from the crop). The parsing client ignores this
    /// extra field; it's carried for consumers that want text for free.
    public let text: String

    public init(label: String, bboxPx: PixelBox, confidence: Float?, position: Int, text: String) {
        self.label = label
        self.bboxPx = bboxPx
        self.confidence = confidence
        self.position = position
        self.text = text
    }
}

/// A structured data value Apple Vision detected on-device (email, phone, postal
/// address, date, money amount, tracking/payment id, …) with its position.
/// Vision surfaces these for free inside `RecognizeDocumentsRequest`; they're
/// valuable as PII pre-detection (redaction) and structured extraction.
public struct DetectedDatum {
    public let kind: String         // "email" | "phone" | "address" | "date" | ...
    public let value: String
    public let bboxPx: PixelBox     // pixels, top-left origin

    public init(kind: String, value: String, bboxPx: PixelBox) {
        self.kind = kind
        self.value = value
        self.bboxPx = bboxPx
    }
}

public struct LayoutResult {
    public let width: Int
    public let height: Int
    public let regions: [LayoutRegion]
    public let detectedData: [DetectedDatum]
    public let decodeMs: Double
    public let layoutMs: Double
}

/// Maps Apple Vision document-element kinds to canonical `piko_layout`
/// ElementLabel value strings (snake_case). Kept pure + centralized so it mirrors
/// surya_server's `SURYA_TO_CANONICAL` and is unit-testable without Vision.
public enum LayoutLabel {
    public static let text = "text"
    public static let sectionHeader = "section_header"
    public static let title = "title"
    public static let table = "table"
    public static let listItem = "list_item"
}

public struct VisionPipeline {
    public let config: VisionPipelineConfig

    public init(config: VisionPipelineConfig) {
        self.config = config
    }

    /// Decode raw image bytes to a CGImage and enforce the max-dimension guard.
    /// Shared by `process()`, `extractWords()`, and `detectLayout()`.
    private func decodeCGImage(_ imageData: Data) throws -> CGImage {
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
        if width > config.maxImageDimensionPx || height > config.maxImageDimensionPx {
            throw VisionError.imageTooLarge(width: width, height: height, maxDimension: config.maxImageDimensionPx)
        }
        return cgImage
    }

    /// Run OCR and return word-level bounding boxes (one box per whitespace-separated token)
    /// in addition to the line-level blocks Vision produces natively.
    public func extractWords(imageData: Data) throws -> OCRWordsResult {
        let startDecode = nowNs()

        let cgImage = try decodeCGImage(imageData)
        let width = cgImage.width
        let height = cgImage.height

        let decodeMs = msFrom(startDecode)

        let startOCR = nowNs()
        let (blocks, words) = try extractTextWithWords(cgImage: cgImage)
        let ocrMs = msFrom(startOCR)

        let ocrQuality = OCRQualityMetrics.compute(from: blocks)

        return OCRWordsResult(
            width: width,
            height: height,
            blocks: blocks,
            words: words,
            ocrQuality: ocrQuality,
            decodeMs: decodeMs,
            ocrMs: ocrMs
        )
    }

    public func process(imageData: Data) throws -> VisionResult {
        let startDecode = nowNs()

        let cgImage = try decodeCGImage(imageData)
        let width = cgImage.width
        let height = cgImage.height

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

    private func extractTextWithWords(cgImage: CGImage) throws -> ([OCRBlock], [OCRWord]) {
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
            return ([], [])
        }

        var blocks: [OCRBlock] = []
        var words: [OCRWord] = []
        blocks.reserveCapacity(results.count)

        for observation in results {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }

            let blockIndex = blocks.count
            blocks.append(OCRBlock(
                text: candidate.string,
                boundingBox: toNormalizedBox(observation.boundingBox),
                confidence: candidate.confidence
            ))

            let fullString = candidate.string
            // Iterate word-like tokens (runs of non-whitespace) and query Vision for tight boxes.
            var idx = fullString.startIndex
            while idx < fullString.endIndex {
                // Skip whitespace
                while idx < fullString.endIndex, fullString[idx].isWhitespace {
                    idx = fullString.index(after: idx)
                }
                guard idx < fullString.endIndex else { break }

                let wordStart = idx
                while idx < fullString.endIndex, !fullString[idx].isWhitespace {
                    idx = fullString.index(after: idx)
                }
                let wordEnd = idx
                let range = wordStart..<wordEnd
                let wordText = String(fullString[range])
                if wordText.isEmpty { continue }

                // Try to get a tight bounding box for this word's character range.
                // Falls back to the line box if the query fails (rare).
                let wordBox: NormalizedBox
                if let rectObs = try? candidate.boundingBox(for: range) {
                    wordBox = toNormalizedBox(rectObs.boundingBox)
                } else {
                    wordBox = toNormalizedBox(observation.boundingBox)
                }

                words.append(OCRWord(
                    text: wordText,
                    boundingBox: wordBox,
                    confidence: candidate.confidence,
                    blockIndex: blockIndex
                ))
            }
        }

        return (blocks, words)
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

    // MARK: - Layout (document structure)

    /// Detect document structure (paragraphs / tables / lists) with Apple's
    /// `RecognizeDocumentsRequest` (macOS 26+) and return one flat, reading-order
    /// sorted region per top-level element, in pixel coordinates matching the
    /// parsing pipeline's `/layout` wire contract.
    ///
    /// GLM refines/OCRs region *content* downstream; this only supplies geometry
    /// + a best-effort canonical label + reading order.
    public func detectLayout(imageData: Data) async throws -> LayoutResult {
        let startDecode = nowNs()
        let cgImage = try decodeCGImage(imageData)
        let width = cgImage.width
        let height = cgImage.height
        let decodeMs = msFrom(startDecode)

        guard #available(macOS 26, *) else {
            throw VisionError.layoutUnavailable
        }
        return try await performDocumentLayout(
            cgImage: cgImage, width: width, height: height, decodeMs: decodeMs)
    }

    /// The macOS-26-only Vision work, isolated so `detectLayout` can compile on the
    /// 13+ floor and fail cleanly at runtime on older systems.
    @available(macOS 26, *)
    private func performDocumentLayout(
        cgImage: CGImage, width: Int, height: Int, decodeMs: Double
    ) async throws -> LayoutResult {
        let startLayout = nowNs()
        let request = RecognizeDocumentsRequest()
        let observations: [DocumentObservation]
        do {
            observations = try await request.perform(on: cgImage)
        } catch {
            throw VisionError.layoutFailed(error.localizedDescription)
        }

        guard let container = observations.first?.document else {
            return LayoutResult(
                width: width, height: height, regions: [], detectedData: [],
                decodeMs: decodeMs, layoutMs: msFrom(startLayout)
            )
        }

        let regions = Self.walkDocument(container, width: width, height: height)
        var detected = Self.extractDetectedData(container, width: width, height: height)
        detected += Self.extractNames(container, width: width, height: height)
        return LayoutResult(
            width: width, height: height, regions: regions, detectedData: detected,
            decodeMs: decodeMs, layoutMs: msFrom(startLayout)
        )
    }

    /// Flatten Vision's on-device data-detector matches (email/phone/address/date/
    /// money/…) with position. Consumes the top-level text and every paragraph —
    /// NOT the nested table-cell / list-item containers, whose `content` recursively
    /// references itself (descending stack-overflows the server). The top-level
    /// text collection already surfaces the matches. Dedupes by (kind, value, box).
    @available(macOS 26, *)
    static func extractDetectedData(
        _ container: DocumentObservation.Container, width: Int, height: Int
    ) -> [DetectedDatum] {
        var out: [DetectedDatum] = []
        var seen = Set<String>()

        func consume(_ text: DocumentObservation.Container.Text) {
            for match in text.detectedData {
                guard let (kind, value) = describeMatch(match.match) else { continue }
                let box = toPixelBox(match.boundingRegion, width: width, height: height)
                let key = "\(kind)|\(value)|\(Int(box.x1))|\(Int(box.y1))"
                if seen.insert(key).inserted {
                    out.append(DetectedDatum(kind: kind, value: value, bboxPx: box))
                }
            }
        }
        consume(container.text)
        for p in container.paragraphs { consume(p) }
        return out
    }

    /// Map a DataDetector match to (kind, value). Pure-ish: the switch is over
    /// Vision enum cases (needs macOS 26), but carries no geometry.
    @available(macOS 26, *)
    static func describeMatch(_ match: DataDetector.Match) -> (String, String)? {
        switch match.details {
        case .link(let l): return ("link", l.url.absoluteString)
        case .emailAddress(let e): return ("email", e.emailAddress)
        case .phoneNumber(let p): return ("phone", p.phoneNumber)
        case .postalAddress(let a):
            return ("address", a.fullAddress.replacingOccurrences(of: "\n", with: ", "))
        case .calendarEvent(let c):
            return c.startDate.map { ("date", ISO8601DateFormatter().string(from: $0)) }
        case .moneyAmount(let m): return ("money", "\(m.amount) \(m.currency.identifier)")
        case .shipmentTrackingNumber(let s): return ("tracking", "\(s.carrier) \(s.trackingNumber)")
        case .measurement(let m): return ("measurement", "\(m.value)")
        case .paymentIdentifier(let p): return ("payment", p.identifier)
        case .flightNumber(let fl): return ("flight", "\(fl.airlineCode)\(fl.flightNumber)")
        @unknown default: return nil
        }
    }

    // MARK: - Name detection (NaturalLanguage NER)

    /// Personal names Apple's `NLTagger` (.nameType) finds in each paragraph's
    /// transcript, mapped back to a pixel box via Vision's `boundingRegion(for:)`.
    /// Apple has no name *data-detector*; NER is a separate on-device framework.
    /// Names are heuristic (some org/role false positives) — acceptable for
    /// redaction, where over-detection is safer than a miss.
    @available(macOS 26, *)
    static func extractNames(
        _ container: DocumentObservation.Container, width: Int, height: Int
    ) -> [DetectedDatum] {
        var out: [DetectedDatum] = []
        var seen = Set<String>()
        let tagger = NLTagger(tagSchemes: [.nameType])
        let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        for paragraph in container.paragraphs {
            let s = paragraph.transcript
            if s.isEmpty { continue }
            tagger.string = s
            tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word,
                                 scheme: .nameType, options: opts) { tag, range in
                guard tag == .personalName else { return true }
                let value = String(s[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isLikelyName(value) else { return true }
                guard let region = paragraph.boundingRegion(for: range) else { return true }
                let box = toPixelBox(region, width: width, height: height)
                let key = "\(value)|\(Int(box.x1))|\(Int(box.y1))"
                if seen.insert(key).inserted {
                    out.append(DetectedDatum(kind: "name", value: value, bboxPx: box))
                }
                return true
            }
        }
        return out
    }

    /// Conservative filter over NLTagger name candidates. Pure + unit-testable.
    /// Drops the common false positives (short filler words like "Ihre"/"Pos",
    /// all-lowercase tokens, non-alphabetic) while keeping real personal names.
    static func isLikelyName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 3 { return false }
        // Must contain a letter and start uppercase (proper noun).
        guard let first = trimmed.first, first.isUppercase else { return false }
        // Reject tokens with digits (article numbers, codes misread as names).
        if trimmed.contains(where: { $0.isNumber }) { return false }
        // A short single common word is likely a header/filler.
        let words = trimmed.split(separator: " ")
        if words.count == 1 {
            if trimmed.count <= 3 { return false }
            // Common German filler words NLTagger mistags as single-word names.
            if nameStopwords.contains(trimmed.lowercased()) { return false }
        }
        return true
    }

    /// Single-token words NLTagger commonly mis-tags as personal names in German
    /// business documents. Only applied to single-word candidates so real
    /// surnames are never dropped.
    static let nameStopwords: Set<String> = [
        "ihre", "ihr", "nach", "vor", "über", "unter", "sehr", "geehrte",
        "herr", "frau", "pos", "art", "menge", "datum", "seite", "kunde",
        "bearbeiter", "vertreter", "porto", "verpackung", "summe",
    ]

    // MARK: - Pure layout helpers

    /// One flat region per top-level element. Vision keeps title/text/tables/lists
    /// in separate collections, so the final list is geometrically sorted into a
    /// single top-to-bottom, left-to-right reading order and re-`position`ed.
    /// Gated behind macOS 26 because the `DocumentObservation.Container` types only
    /// exist there; the geometry/label logic it delegates to is pure + testable.
    @available(macOS 26, *)
    static func walkDocument(
        _ container: DocumentObservation.Container,
        width: Int,
        height: Int
    ) -> [LayoutRegion] {
        var raw: [RawRegion] = []

        // Tables and list items first, so their boxes can suppress the duplicate
        // paragraphs Vision emits for the same content.

        // One region per table (its bounding region) — NOT one per cell. GLM
        // transcribes the table crop downstream, exactly as with surya/paddle, so
        // no table text is carried here.
        for table in container.tables {
            raw.append(RawRegion(
                label: LayoutLabel.table,
                box: toPixelBox(table.boundingRegion, width: width, height: height),
                confidence: nil, text: ""))
        }

        var claimedBoxes: [PixelBox] = []
        for list in container.lists {
            for item in list.items {
                // List `Item` has no boundingRegion of its own; its `content`
                // container carries the geometry.
                let box = toPixelBox(item.content.boundingRegion, width: width, height: height)
                claimedBoxes.append(box)
                raw.append(RawRegion(label: LayoutLabel.listItem, box: box,
                                     confidence: nil, text: item.itemString))
            }
        }

        // Document title, when Vision identifies one. Track its box so the
        // matching paragraph below isn't emitted a second time.
        if let title = container.title {
            let box = toPixelBox(title.boundingRegion, width: width, height: height)
            claimedBoxes.append(box)
            raw.append(RawRegion(label: LayoutLabel.title, box: box,
                                 confidence: nil, text: title.transcript))
        }

        for paragraph in container.paragraphs {
            let box = toPixelBox(paragraph.boundingRegion, width: width, height: height)
            // Skip a paragraph already represented as a title or list item —
            // Vision returns the same content in both `paragraphs` and `lists`.
            if claimedBoxes.contains(where: { boxesOverlapHeavily($0, box) }) { continue }
            // Trust Vision's own title signal; default everything else to text.
            // (A word-count heuristic mislabeled almost every line on dense forms.)
            let isHeader = paragraph.lines.contains { $0.isTitle }
            let label = isHeader ? LayoutLabel.sectionHeader : LayoutLabel.text
            raw.append(RawRegion(label: label, box: box,
                                 confidence: nil, text: paragraph.transcript))
        }

        return orderRegions(raw)
    }

    /// True if `b` is largely contained in `a` (or vice versa) — used to drop the
    /// duplicate paragraph Vision emits for a region it also reports as a list item
    /// or title. Pure + unit-testable. Threshold: overlap ≥ 80% of the smaller box.
    static func boxesOverlapHeavily(_ a: PixelBox, _ b: PixelBox) -> Bool {
        let ix1 = max(a.x1, b.x1), iy1 = max(a.y1, b.y1)
        let ix2 = min(a.x2, b.x2), iy2 = min(a.y2, b.y2)
        let iw = ix2 - ix1, ih = iy2 - iy1
        guard iw > 0, ih > 0 else { return false }
        let inter = iw * ih
        let areaA = max(0, a.x2 - a.x1) * max(0, a.y2 - a.y1)
        let areaB = max(0, b.x2 - b.x1) * max(0, b.y2 - b.y1)
        let smaller = min(areaA, areaB)
        guard smaller > 0 else { return false }
        return inter / smaller >= 0.8
    }

    /// Sort raw regions into reading order (top-to-bottom, then left-to-right) and
    /// assign sequential `position`. Pure — the sort input is already-converted
    /// pixel boxes, so this is fully unit-testable.
    static func orderRegions(_ raw: [RawRegion]) -> [LayoutRegion] {
        let sorted = raw.enumerated().sorted { a, b in
            // Primary: top edge. Secondary: left edge. Tertiary: original index
            // (stable, deterministic tie-break).
            if a.element.box.y1 != b.element.box.y1 {
                return a.element.box.y1 < b.element.box.y1
            }
            if a.element.box.x1 != b.element.box.x1 {
                return a.element.box.x1 < b.element.box.x1
            }
            return a.offset < b.offset
        }
        return sorted.enumerated().map { position, entry in
            LayoutRegion(
                label: entry.element.label,
                bboxPx: entry.element.box,
                confidence: entry.element.confidence,
                position: position,
                text: entry.element.text
            )
        }
    }
}

/// Pre-ordering region tuple. Named (not an anonymous tuple) so the pure
/// `orderRegions` is easy to construct in tests without Vision.
public struct RawRegion {
    public let label: String
    public let box: PixelBox
    public let confidence: Float?
    public let text: String

    public init(label: String, box: PixelBox, confidence: Float?, text: String) {
        self.label = label
        self.box = box
        self.confidence = confidence
        self.text = text
    }
}

// MARK: - Coordinate conversion (the one place geometry is converted)

/// Convert a Vision `NormalizedRegion` (macOS 26 document API) to a pixel-space,
/// top-left-origin `PixelBox` matching the `/layout` wire contract.
///
/// Vision's own `NormalizedRect.toImageCoordinates(_:origin:)` does the scale +
/// origin flip; passing `.upperLeft` yields a top-left-origin pixel `CGRect`
/// directly, so there is no hand-rolled coordinate math to get wrong.
@available(macOS 26, *)
func toPixelBox(_ region: NormalizedRegion, width: Int, height: Int) -> PixelBox {
    let imageSize = CGSize(width: width, height: height)
    let rect = region.boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)
    return PixelBox(
        x1: Double(rect.minX),
        y1: Double(rect.minY),
        x2: Double(rect.maxX),
        y2: Double(rect.maxY)
    )
}
