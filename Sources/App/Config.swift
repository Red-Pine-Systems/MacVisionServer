import Foundation
import VisionCore

struct Config {
    let port: Int
    let maxInflight: Int
    let maxQueue: Int
    let maxQueueWaitMs: Int
    let maxProcessingMs: Int
    let maxUploadBytes: Int
    let maxImageDimensionPx: Int
    let ocrLevel: VisionPipelineConfig.OCRLevel
    let ocrLangCorrection: Bool
    let ocrLangs: [String]

    static func load() -> Config {
        let maxInflight = env("MAX_INFLIGHT", default: 4)
        let maxQueueDefault = min(maxInflight * 50, 1000)

        return Config(
            port: env("PORT", default: 3100),
            maxInflight: maxInflight,
            maxQueue: env("MAX_QUEUE", default: maxQueueDefault),
            maxQueueWaitMs: env("MAX_QUEUE_WAIT_MS", default: 5000),
            maxProcessingMs: env("MAX_PROCESSING_MS", default: 60000),
            maxUploadBytes: env("MAX_UPLOAD_BYTES", default: 15_000_000),
            maxImageDimensionPx: env("MAX_IMAGE_DIMENSION_PX", default: 6000),
            ocrLevel: env("OCR_LEVEL", default: "accurate") == "fast" ? .fast : .accurate,
            ocrLangCorrection: env("OCR_LANG_CORRECTION", default: true),
            ocrLangs: env("OCR_LANGS", default: "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
    }

    /// Convert to VisionPipelineConfig for the core library
    func toVisionPipelineConfig() -> VisionPipelineConfig {
        VisionPipelineConfig(
            maxImageDimensionPx: maxImageDimensionPx,
            ocrLevel: ocrLevel,
            ocrLangCorrection: ocrLangCorrection,
            ocrLangs: ocrLangs
        )
    }
}

private func env(_ key: String, default defaultValue: Int) -> Int {
    if let str = ProcessInfo.processInfo.environment[key], let val = Int(str) {
        return val
    }
    return defaultValue
}

private func env(_ key: String, default defaultValue: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? defaultValue
}

private func env(_ key: String, default defaultValue: Bool) -> Bool {
    if let str = ProcessInfo.processInfo.environment[key]?.lowercased() {
        return str == "true" || str == "1" || str == "yes"
    }
    return defaultValue
}
