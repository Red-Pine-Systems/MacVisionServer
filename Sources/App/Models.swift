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
    case internalError(String)

    var code: String {
        switch self {
        case .invalidImage: return "invalid_image"
        case .payloadTooLarge: return "payload_too_large"
        case .unsupportedMediaType: return "unsupported_media_type"
        case .overloaded: return "overloaded"
        case .imageTooLarge: return "image_too_large"
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
