import Vapor
import Foundation
import VisionCore

func routes(_ app: Application, config: Config, jobQueue: JobQueue, pipeline: VisionPipeline) throws {
    // Health endpoint
    app.get("health") { req async -> HealthResponse in
        let stats = await jobQueue.getStats()
        return HealthResponse(
            status: "ok",
            inflight: stats.inflight,
            queueDepth: stats.queueDepth,
            totalProcessed: stats.totalProcessed,
            totalErrors: stats.totalErrors,
            totalOverloaded: stats.totalOverloaded
        )
    }

    // Analyze endpoint
    app.on(.POST, "analyze", body: .collect(maxSize: ByteCount(value: config.maxUploadBytes))) { req async throws -> Response in
        let requestStart = nowNs()
        let requestId = req.headers.first(name: "X-Request-Id")

        // Helper to create error response
        func errorResponse(_ error: APIError) -> Response {
            let errorBody = ErrorResponse(error: ErrorDetail(
                code: error.code,
                message: error.message,
                requestId: requestId
            ))

            var headers = HTTPHeaders()
            headers.contentType = .json
            if let retryAfter = error.retryAfterSeconds {
                headers.add(name: "Retry-After", value: String(retryAfter))
            }

            let body: Response.Body
            do {
                let encoded = try JSONEncoder().encode(errorBody)
                body = .init(data: encoded)
            } catch {
                body = .init(string: "{\"error\":{\"code\":\"internal_error\",\"message\":\"Failed to encode error\"}}")
            }

            logRequest(
                requestId: requestId,
                status: Int(error.httpStatus.code),
                queueWaitMs: 0,
                totalMs: msFrom(requestStart),
                faceCount: nil,
                ocrBlockCount: nil,
                errorCode: error.code
            )

            return Response(status: error.httpStatus, headers: headers, body: body)
        }

        // Parse multipart form data
        guard let contentType = req.headers.contentType,
              contentType.type == "multipart" else {
            return errorResponse(.unsupportedMediaType)
        }

        // Get image data from multipart
        guard let imageData = try? req.content.get(Data.self, at: "image"),
              !imageData.isEmpty else {
            return errorResponse(.invalidImage)
        }

        // Check payload size
        if imageData.count > config.maxUploadBytes {
            return errorResponse(.payloadTooLarge(maxBytes: config.maxUploadBytes))
        }

        // Try to enqueue the job
        let jobId = requestId ?? UUID().uuidString
        let enqueueResult = await jobQueue.tryEnqueue(jobId: jobId)

        switch enqueueResult {
        case .failure(let error):
            let retryAfter = config.maxQueueWaitMs / 1000 + 1
            switch error {
            case .queueFull:
                return errorResponse(.overloaded(retryAfterSeconds: retryAfter))
            case .queueWaitTimeout:
                return errorResponse(.overloaded(retryAfterSeconds: retryAfter))
            case .processingTimeout:
                return errorResponse(.overloaded(retryAfterSeconds: retryAfter))
            }
        case .success:
            break
        }

        let queueWaitMs = msFrom(requestStart)

        // Process the image (wrap in autoreleasepool for memory management)
        let result: Result<VisionResult, Error> = autoreleasepool {
            do {
                let visionResult = try pipeline.process(imageData: imageData)
                return .success(visionResult)
            } catch {
                return .failure(error)
            }
        }

        // Mark job complete
        let success: Bool
        switch result {
        case .success: success = true
        case .failure: success = false
        }
        await jobQueue.complete(success: success)

        // Handle result
        switch result {
        case .failure(let error):
            if let visionError = error as? VisionError {
                switch visionError {
                case .invalidImageData, .decodeFailed:
                    return errorResponse(.invalidImage)
                case .imageTooLarge(let w, let h, let max):
                    return errorResponse(.imageTooLarge(width: w, height: h, maxDimension: max))
                case .faceDetectionFailed(let msg), .ocrFailed(let msg):
                    return errorResponse(.internalError(msg))
                }
            }
            return errorResponse(.internalError(error.localizedDescription))

        case .success(let visionResult):
            let totalMs = msFrom(requestStart)

            let response = AnalyzeResponse(
                schemaVersion: "1.0",
                requestId: requestId,
                faces: FacesResponse(
                    detected: !visionResult.faces.isEmpty,
                    count: visionResult.faces.count,
                    items: visionResult.faces.map { face in
                        FaceItem(
                            boundingBox: BoundingBoxResponse(
                                x: face.boundingBox.x,
                                y: face.boundingBox.y,
                                width: face.boundingBox.width,
                                height: face.boundingBox.height
                            ),
                            confidence: face.confidence
                        )
                    }
                ),
                ocr: OCRResponse(
                    ran: true,
                    quality: OCRQualityResponse(
                        avgConfidence: visionResult.ocrQuality.avgConfidence,
                        minConfidence: visionResult.ocrQuality.minConfidence,
                        lowConfidenceRatio: visionResult.ocrQuality.lowConfidenceRatio,
                        lowConfidenceBlockCount: visionResult.ocrQuality.lowConfidenceBlockCount,
                        totalBlockCount: visionResult.ocrQuality.totalBlockCount
                    ),
                    blocks: visionResult.ocrBlocks.map { block in
                        OCRBlockResponse(
                            text: block.text,
                            boundingBox: BoundingBoxResponse(
                                x: block.boundingBox.x,
                                y: block.boundingBox.y,
                                width: block.boundingBox.width,
                                height: block.boundingBox.height
                            ),
                            confidence: block.confidence
                        )
                    }
                ),
                metrics: MetricsResponse(
                    imageBytes: imageData.count,
                    widthPx: visionResult.width,
                    heightPx: visionResult.height,
                    queueWaitMs: queueWaitMs,
                    decodeMs: visionResult.decodeMs,
                    faceMs: visionResult.faceMs,
                    ocrMs: visionResult.ocrMs,
                    totalMs: totalMs
                ),
                server: ServerInfo.current()
            )

            logRequest(
                requestId: requestId,
                status: 200,
                queueWaitMs: queueWaitMs,
                totalMs: totalMs,
                faceCount: visionResult.faces.count,
                ocrBlockCount: visionResult.ocrBlocks.count,
                errorCode: nil
            )

            return try await response.encodeResponse(for: req)
        }
    }
}

// MARK: - Request Logging

private func logRequest(
    requestId: String?,
    status: Int,
    queueWaitMs: Double,
    totalMs: Double,
    faceCount: Int?,
    ocrBlockCount: Int?,
    errorCode: String?
) {
    var log: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "status": status,
        "queue_wait_ms": round(queueWaitMs * 10) / 10,
        "total_ms": round(totalMs * 10) / 10
    ]

    if let requestId = requestId {
        log["request_id"] = requestId
    }
    if let faceCount = faceCount {
        log["face_count"] = faceCount
    }
    if let ocrBlockCount = ocrBlockCount {
        log["ocr_block_count"] = ocrBlockCount
    }
    if let errorCode = errorCode {
        log["error_code"] = errorCode
    }

    // Output as JSON line
    if let jsonData = try? JSONSerialization.data(withJSONObject: log, options: []),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    }
}
