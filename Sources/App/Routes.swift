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
                case .faceDetectionFailed(let msg), .ocrFailed(let msg), .layoutFailed(let msg):
                    return errorResponse(.internalError(msg))
                case .layoutUnavailable:
                    return errorResponse(.layoutUnavailable)
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

    // Layout (document structure) endpoint — mirrors the parsing pipeline's
    // `/layout` wire contract. JSON body `{"image_b64": "..."}` in, pixel boxes out.
    app.on(.POST, "layout", body: .collect(maxSize: ByteCount(value: config.maxUploadBytes))) { req async throws -> Response in
        let requestStart = nowNs()
        let requestId = req.headers.first(name: "X-Request-Id")

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

        // JSON body with base64-encoded image (not multipart, unlike /analyze).
        guard let requestBody = try? req.content.decode(LayoutRequestBody.self) else {
            return errorResponse(.invalidImage)
        }
        guard let imageData = Data(base64Encoded: requestBody.imageB64), !imageData.isEmpty else {
            return errorResponse(.invalidImage)
        }

        if imageData.count > config.maxUploadBytes {
            return errorResponse(.payloadTooLarge(maxBytes: config.maxUploadBytes))
        }

        let jobId = requestId ?? UUID().uuidString
        let enqueueResult = await jobQueue.tryEnqueue(jobId: jobId)

        switch enqueueResult {
        case .failure(let error):
            let retryAfter = config.maxQueueWaitMs / 1000 + 1
            switch error {
            case .queueFull, .queueWaitTimeout, .processingTimeout:
                return errorResponse(.overloaded(retryAfterSeconds: retryAfter))
            }
        case .success:
            break
        }

        let queueWaitMs = msFrom(requestStart)

        // detectLayout is async (RecognizeDocumentsRequest.perform is async), so it
        // cannot be wrapped in autoreleasepool across the suspension point.
        let result: Result<LayoutResult, Error>
        do {
            let layoutResult = try await pipeline.detectLayout(imageData: imageData)
            result = .success(layoutResult)
        } catch {
            result = .failure(error)
        }

        let success: Bool
        switch result {
        case .success: success = true
        case .failure: success = false
        }
        await jobQueue.complete(success: success)

        switch result {
        case .failure(let error):
            if let visionError = error as? VisionError {
                switch visionError {
                case .invalidImageData, .decodeFailed:
                    return errorResponse(.invalidImage)
                case .imageTooLarge(let w, let h, let max):
                    return errorResponse(.imageTooLarge(width: w, height: h, maxDimension: max))
                case .layoutUnavailable:
                    return errorResponse(.layoutUnavailable)
                case .faceDetectionFailed(let msg), .ocrFailed(let msg), .layoutFailed(let msg):
                    return errorResponse(.internalError(msg))
                }
            }
            return errorResponse(.internalError(error.localizedDescription))

        case .success(let layoutResult):
            let totalMs = msFrom(requestStart)

            let boxes = layoutResult.regions.map { region -> LayoutBoxResponse in
                let b = region.bboxPx
                return LayoutBoxResponse(
                    polygon: [[b.x1, b.y1], [b.x2, b.y1], [b.x2, b.y2], [b.x1, b.y2]],
                    bbox: [b.x1, b.y1, b.x2, b.y2],
                    label: region.label,
                    confidence: region.confidence,
                    position: region.position,
                    text: region.text
                )
            }

            let detectedData = layoutResult.detectedData.map { d -> DetectedDataResponse in
                let b = d.bboxPx
                return DetectedDataResponse(kind: d.kind, value: d.value,
                                            bbox: [b.x1, b.y1, b.x2, b.y2])
            }

            let response = LayoutResponse(
                image: [layoutResult.width, layoutResult.height],
                boxes: boxes,
                detectedData: detectedData
            )

            logRequest(
                requestId: requestId,
                status: 200,
                queueWaitMs: queueWaitMs,
                totalMs: totalMs,
                faceCount: nil,
                ocrBlockCount: layoutResult.regions.count,
                errorCode: nil
            )

            return try await response.encodeResponse(for: req)
        }
    }

    // Word-level OCR endpoint
    app.on(.POST, "ocr", "words", body: .collect(maxSize: ByteCount(value: config.maxUploadBytes))) { req async throws -> Response in
        let requestStart = nowNs()
        let requestId = req.headers.first(name: "X-Request-Id")

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

        guard let contentType = req.headers.contentType,
              contentType.type == "multipart" else {
            return errorResponse(.unsupportedMediaType)
        }

        guard let imageData = try? req.content.get(Data.self, at: "image"),
              !imageData.isEmpty else {
            return errorResponse(.invalidImage)
        }

        if imageData.count > config.maxUploadBytes {
            return errorResponse(.payloadTooLarge(maxBytes: config.maxUploadBytes))
        }

        let jobId = requestId ?? UUID().uuidString
        let enqueueResult = await jobQueue.tryEnqueue(jobId: jobId)

        switch enqueueResult {
        case .failure(let error):
            let retryAfter = config.maxQueueWaitMs / 1000 + 1
            switch error {
            case .queueFull, .queueWaitTimeout, .processingTimeout:
                return errorResponse(.overloaded(retryAfterSeconds: retryAfter))
            }
        case .success:
            break
        }

        let queueWaitMs = msFrom(requestStart)

        let result: Result<OCRWordsResult, Error> = autoreleasepool {
            do {
                let wordsResult = try pipeline.extractWords(imageData: imageData)
                return .success(wordsResult)
            } catch {
                return .failure(error)
            }
        }

        let success: Bool
        switch result {
        case .success: success = true
        case .failure: success = false
        }
        await jobQueue.complete(success: success)

        switch result {
        case .failure(let error):
            if let visionError = error as? VisionError {
                switch visionError {
                case .invalidImageData, .decodeFailed:
                    return errorResponse(.invalidImage)
                case .imageTooLarge(let w, let h, let max):
                    return errorResponse(.imageTooLarge(width: w, height: h, maxDimension: max))
                case .faceDetectionFailed(let msg), .ocrFailed(let msg), .layoutFailed(let msg):
                    return errorResponse(.internalError(msg))
                case .layoutUnavailable:
                    return errorResponse(.layoutUnavailable)
                }
            }
            return errorResponse(.internalError(error.localizedDescription))

        case .success(let wordsResult):
            let totalMs = msFrom(requestStart)

            let response = OCRWordsResponse(
                schemaVersion: "1.0",
                requestId: requestId,
                ocr: OCRWordsBody(
                    quality: OCRQualityResponse(
                        avgConfidence: wordsResult.ocrQuality.avgConfidence,
                        minConfidence: wordsResult.ocrQuality.minConfidence,
                        lowConfidenceRatio: wordsResult.ocrQuality.lowConfidenceRatio,
                        lowConfidenceBlockCount: wordsResult.ocrQuality.lowConfidenceBlockCount,
                        totalBlockCount: wordsResult.ocrQuality.totalBlockCount
                    ),
                    blocks: wordsResult.blocks.map { block in
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
                    },
                    words: wordsResult.words.map { word in
                        OCRWordResponse(
                            text: word.text,
                            boundingBox: BoundingBoxResponse(
                                x: word.boundingBox.x,
                                y: word.boundingBox.y,
                                width: word.boundingBox.width,
                                height: word.boundingBox.height
                            ),
                            confidence: word.confidence,
                            blockIndex: word.blockIndex
                        )
                    }
                ),
                metrics: WordsMetricsResponse(
                    imageBytes: imageData.count,
                    widthPx: wordsResult.width,
                    heightPx: wordsResult.height,
                    queueWaitMs: queueWaitMs,
                    decodeMs: wordsResult.decodeMs,
                    ocrMs: wordsResult.ocrMs,
                    totalMs: totalMs
                ),
                server: ServerInfo.current()
            )

            logRequest(
                requestId: requestId,
                status: 200,
                queueWaitMs: queueWaitMs,
                totalMs: totalMs,
                faceCount: nil,
                ocrBlockCount: wordsResult.blocks.count,
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
