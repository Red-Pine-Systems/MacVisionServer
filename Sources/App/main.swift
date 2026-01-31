import Vapor
import Foundation
import VisionCore

@main
enum VisionServer {
    static func main() async throws {
        let config = Config.load()

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        // Configure server
        app.http.server.configuration.hostname = "0.0.0.0"
        app.http.server.configuration.port = config.port

        // Create shared instances
        let jobQueue = JobQueue(config: config)
        let pipeline = VisionPipeline(config: config.toVisionPipelineConfig())

        // Register routes
        try routes(app, config: config, jobQueue: jobQueue, pipeline: pipeline)

        // Print startup info
        print("Vision Server starting...")
        print("  Port: \(config.port)")
        print("  Max Inflight: \(config.maxInflight)")
        print("  Max Queue: \(config.maxQueue)")
        print("  Max Queue Wait: \(config.maxQueueWaitMs)ms")
        print("  Max Processing: \(config.maxProcessingMs)ms")
        print("  Max Upload: \(config.maxUploadBytes) bytes")
        print("  Max Image Dimension: \(config.maxImageDimensionPx)px")
        print("  OCR Level: \(config.ocrLevel == .fast ? "fast" : "accurate")")
        print("  OCR Language Correction: \(config.ocrLangCorrection)")
        if !config.ocrLangs.isEmpty {
            print("  OCR Languages: \(config.ocrLangs.joined(separator: ", "))")
        }
        print("---")

        try await app.execute()
        try await app.asyncShutdown()
    }
}
