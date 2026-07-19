import Foundation
import Vapor

// MARK: - Response Models

struct AnalyzeResponse: Content {
    let schemaVersion: String
    let requestId: String?
    let faces: FacesResponse
    let ocr: OCRResponse
    let metrics: MetricsResponse
    let server: ServerInfo

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestId = "request_id"
        case faces, ocr, metrics, server
    }
}

struct FacesResponse: Content {
    let detected: Bool
    let count: Int
    let items: [FaceItem]
}

struct FaceItem: Content {
    let boundingBox: BoundingBoxResponse
    let confidence: Float?

    enum CodingKeys: String, CodingKey {
        case boundingBox = "bounding_box"
        case confidence
    }
}

struct OCRResponse: Content {
    let ran: Bool
    let quality: OCRQualityResponse
    let blocks: [OCRBlockResponse]
}

struct OCRQualityResponse: Content {
    let avgConfidence: Float
    let minConfidence: Float
    let lowConfidenceRatio: Float
    let lowConfidenceBlockCount: Int
    let totalBlockCount: Int

    enum CodingKeys: String, CodingKey {
        case avgConfidence = "avg_confidence"
        case minConfidence = "min_confidence"
        case lowConfidenceRatio = "low_confidence_ratio"
        case lowConfidenceBlockCount = "low_confidence_block_count"
        case totalBlockCount = "total_block_count"
    }
}

struct OCRBlockResponse: Content {
    let text: String
    let boundingBox: BoundingBoxResponse
    let confidence: Float?

    enum CodingKeys: String, CodingKey {
        case text
        case boundingBox = "bounding_box"
        case confidence
    }
}

struct BoundingBoxResponse: Content {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct MetricsResponse: Content {
    let imageBytes: Int
    let widthPx: Int
    let heightPx: Int
    let queueWaitMs: Double
    let decodeMs: Double
    let faceMs: Double
    let ocrMs: Double
    let totalMs: Double

    enum CodingKeys: String, CodingKey {
        case imageBytes = "image_bytes"
        case widthPx = "width_px"
        case heightPx = "height_px"
        case queueWaitMs = "queue_wait_ms"
        case decodeMs = "decode_ms"
        case faceMs = "face_ms"
        case ocrMs = "ocr_ms"
        case totalMs = "total_ms"
    }
}

struct ServerInfo: Content {
    let serviceVersion: String
    let macosVersion: String

    enum CodingKeys: String, CodingKey {
        case serviceVersion = "service_version"
        case macosVersion = "macos_version"
    }

    static func current() -> ServerInfo {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let macosVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        return ServerInfo(
            serviceVersion: "1.0.0",
            macosVersion: macosVersionString
        )
    }
}

// MARK: - Word-level OCR Response

struct OCRWordsResponse: Content {
    let schemaVersion: String
    let requestId: String?
    let ocr: OCRWordsBody
    let metrics: WordsMetricsResponse
    let server: ServerInfo

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestId = "request_id"
        case ocr, metrics, server
    }
}

struct OCRWordsBody: Content {
    let quality: OCRQualityResponse
    let blocks: [OCRBlockResponse]
    let words: [OCRWordResponse]
}

struct OCRWordResponse: Content {
    let text: String
    let boundingBox: BoundingBoxResponse
    let confidence: Float?
    let blockIndex: Int

    enum CodingKeys: String, CodingKey {
        case text
        case boundingBox = "bounding_box"
        case confidence
        case blockIndex = "block_index"
    }
}

struct WordsMetricsResponse: Content {
    let imageBytes: Int
    let widthPx: Int
    let heightPx: Int
    let queueWaitMs: Double
    let decodeMs: Double
    let ocrMs: Double
    let totalMs: Double

    enum CodingKeys: String, CodingKey {
        case imageBytes = "image_bytes"
        case widthPx = "width_px"
        case heightPx = "height_px"
        case queueWaitMs = "queue_wait_ms"
        case decodeMs = "decode_ms"
        case ocrMs = "ocr_ms"
        case totalMs = "total_ms"
    }
}

// MARK: - Layout (document structure) Request/Response
//
// Mirrors the parsing pipeline's `/layout` wire contract (piko_layout/wire.py):
// request `{"image_b64": "<base64 PNG>"}`, response `{"image": [w, h], "boxes": [...]}`
// in PIXELS. `label` is a canonical snake_case ElementLabel; unmapped labels are
// dropped (not fatal) client-side.

struct LayoutRequestBody: Content {
    let imageB64: String

    enum CodingKeys: String, CodingKey {
        case imageB64 = "image_b64"
    }
}

struct LayoutResponse: Content {
    let image: [Int]                 // [width_px, height_px]
    let boxes: [LayoutBoxResponse]
    // Apple Vision's on-device data-detector hits (email/phone/address/date/…)
    // with position. Extra vs. the parsing contract; valuable for PII redaction
    // and structured extraction.
    let detectedData: [DetectedDataResponse]
    // Whole-image classification (document / handwriting / art …) — page-type
    // routing signal.
    let classification: [ClassificationResponse]
    // Segmented page boundary as a pixel quad (auto-crop / deskew). Null if none.
    let documentQuad: DocumentQuadResponse?

    enum CodingKeys: String, CodingKey {
        case image, boxes, classification
        case detectedData = "detected_data"
        case documentQuad = "document_quad"
    }
}

struct ClassificationResponse: Content {
    let identifier: String
    let confidence: Float
}

struct DocumentQuadResponse: Content {
    let topLeft: [Double]
    let topRight: [Double]
    let bottomRight: [Double]
    let bottomLeft: [Double]
    let confidence: Float

    enum CodingKeys: String, CodingKey {
        case topLeft = "top_left"
        case topRight = "top_right"
        case bottomRight = "bottom_right"
        case bottomLeft = "bottom_left"
        case confidence
    }
}

struct DetectedDataResponse: Content {
    let kind: String                 // email | phone | address | date | money | ...
    let value: String
    let bbox: [Double]               // [x1, y1, x2, y2], pixels
}

struct LayoutBoxResponse: Content {
    let polygon: [[Double]]          // 4 [x, y] corners, pixels
    let bbox: [Double]               // [x1, y1, x2, y2], pixels
    let label: String                // canonical snake_case ElementLabel
    let confidence: Float?
    let position: Int
    // Vision's transcribed text for this region (empty for tables, whose content
    // is transcribed downstream from the crop). Extra vs. the parsing wire
    // contract, which ignores unknown fields; carried so consumers get Apple
    // Vision's on-device text for free (handwriting, PII pre-detection, etc.).
    let text: String
    // Finer-grained boxes inside the region: recognized lines and words, each
    // with its text + pixel bbox. For precise redaction / region OCR.
    let lines: [SubBoxResponse]
    let words: [SubBoxResponse]
}

struct SubBoxResponse: Content {
    let text: String
    let bbox: [Double]               // [x1, y1, x2, y2], pixels
}

// MARK: - Error Response

struct ErrorResponse: Content {
    let error: ErrorDetail
}

struct ErrorDetail: Content {
    let code: String
    let message: String
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case code, message
        case requestId = "request_id"
    }
}

enum APIError: Error {
    case invalidImage
    case payloadTooLarge(maxBytes: Int)
    case unsupportedMediaType
    case overloaded(retryAfterSeconds: Int)
    case imageTooLarge(width: Int, height: Int, maxDimension: Int)
    case layoutUnavailable
    case internalError(String)

    var code: String {
        switch self {
        case .invalidImage: return "invalid_image"
        case .payloadTooLarge: return "payload_too_large"
        case .unsupportedMediaType: return "unsupported_media_type"
        case .overloaded: return "overloaded"
        case .imageTooLarge: return "image_too_large"
        case .layoutUnavailable: return "layout_unavailable"
        case .internalError: return "internal_error"
        }
    }

    var message: String {
        switch self {
        case .invalidImage:
            return "The provided image data is invalid or corrupted"
        case .payloadTooLarge(let maxBytes):
            return "Request body exceeds maximum size of \(maxBytes) bytes"
        case .unsupportedMediaType:
            return "Content-Type must be multipart/form-data with a 'image' field containing JPEG data"
        case .overloaded(let retryAfter):
            return "Server is overloaded, please retry after \(retryAfter) seconds"
        case .imageTooLarge(let width, let height, let maxDimension):
            return "Image dimensions \(width)x\(height) exceed maximum of \(maxDimension)px"
        case .layoutUnavailable:
            return "Document layout detection requires macOS 26 or newer"
        case .internalError(let detail):
            return "Internal server error: \(detail)"
        }
    }

    var httpStatus: HTTPStatus {
        switch self {
        case .invalidImage: return .badRequest
        case .payloadTooLarge: return .payloadTooLarge
        case .unsupportedMediaType: return .unsupportedMediaType
        case .overloaded: return .serviceUnavailable
        case .imageTooLarge: return .badRequest
        case .layoutUnavailable: return .notImplemented
        case .internalError: return .internalServerError
        }
    }

    var retryAfterSeconds: Int? {
        if case .overloaded(let seconds) = self {
            return seconds
        }
        return nil
    }
}

// MARK: - Health Response

struct HealthResponse: Content {
    let status: String
    let inflight: Int
    let queueDepth: Int
    let totalProcessed: Int
    let totalErrors: Int
    let totalOverloaded: Int

    enum CodingKeys: String, CodingKey {
        case status, inflight
        case queueDepth = "queue_depth"
        case totalProcessed = "total_processed"
        case totalErrors = "total_errors"
        case totalOverloaded = "total_overloaded"
    }
}
