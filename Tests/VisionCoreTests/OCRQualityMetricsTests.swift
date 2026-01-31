import XCTest
@testable import VisionCore

final class OCRQualityMetricsTests: XCTestCase {

    // MARK: - Empty Blocks

    func testEmptyBlocks_returnsDefaultValues() {
        let metrics = OCRQualityMetrics.compute(from: [])

        XCTAssertEqual(metrics.avgConfidence, 1.0)
        XCTAssertEqual(metrics.minConfidence, 1.0)
        XCTAssertEqual(metrics.lowConfidenceRatio, 0.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 0)
        XCTAssertEqual(metrics.totalBlockCount, 0)
    }

    // MARK: - Single Block

    func testSingleBlock_highConfidence() {
        let blocks = [makeBlock(confidence: 0.95)]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 0.95)
        XCTAssertEqual(metrics.minConfidence, 0.95)
        XCTAssertEqual(metrics.lowConfidenceRatio, 0.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 0)
        XCTAssertEqual(metrics.totalBlockCount, 1)
    }

    func testSingleBlock_lowConfidence() {
        let blocks = [makeBlock(confidence: 0.5)]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 0.5)
        XCTAssertEqual(metrics.minConfidence, 0.5)
        XCTAssertEqual(metrics.lowConfidenceRatio, 1.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 1)
        XCTAssertEqual(metrics.totalBlockCount, 1)
    }

    func testSingleBlock_exactlyAtThreshold() {
        // 0.7 is the default threshold, blocks AT threshold are NOT low confidence
        let blocks = [makeBlock(confidence: 0.7)]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 0.7)
        XCTAssertEqual(metrics.minConfidence, 0.7)
        XCTAssertEqual(metrics.lowConfidenceRatio, 0.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 0)
        XCTAssertEqual(metrics.totalBlockCount, 1)
    }

    func testSingleBlock_justBelowThreshold() {
        let blocks = [makeBlock(confidence: 0.69)]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.lowConfidenceBlockCount, 1)
        XCTAssertEqual(metrics.lowConfidenceRatio, 1.0)
    }

    // MARK: - Multiple Blocks

    func testMultipleBlocks_allHighConfidence() {
        let blocks = [
            makeBlock(confidence: 0.9),
            makeBlock(confidence: 0.85),
            makeBlock(confidence: 0.95),
            makeBlock(confidence: 0.8)
        ]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 0.875, accuracy: 0.001)
        XCTAssertEqual(metrics.minConfidence, 0.8)
        XCTAssertEqual(metrics.lowConfidenceRatio, 0.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 0)
        XCTAssertEqual(metrics.totalBlockCount, 4)
    }

    func testMultipleBlocks_allLowConfidence() {
        let blocks = [
            makeBlock(confidence: 0.3),
            makeBlock(confidence: 0.4),
            makeBlock(confidence: 0.5),
            makeBlock(confidence: 0.6)
        ]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 0.45, accuracy: 0.001)
        XCTAssertEqual(metrics.minConfidence, 0.3)
        XCTAssertEqual(metrics.lowConfidenceRatio, 1.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 4)
        XCTAssertEqual(metrics.totalBlockCount, 4)
    }

    func testMultipleBlocks_mixedConfidence() {
        // 10 blocks: 8 high, 2 low
        let blocks = [
            makeBlock(confidence: 0.9),
            makeBlock(confidence: 0.85),
            makeBlock(confidence: 0.92),
            makeBlock(confidence: 0.88),
            makeBlock(confidence: 0.95),
            makeBlock(confidence: 0.82),
            makeBlock(confidence: 0.91),
            makeBlock(confidence: 0.87),
            makeBlock(confidence: 0.5),  // low
            makeBlock(confidence: 0.3)   // low
        ]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        // avg = (0.9+0.85+0.92+0.88+0.95+0.82+0.91+0.87+0.5+0.3) / 10 = 7.9 / 10 = 0.79
        XCTAssertEqual(metrics.avgConfidence, 0.79, accuracy: 0.001)
        XCTAssertEqual(metrics.minConfidence, 0.3)
        XCTAssertEqual(metrics.lowConfidenceRatio, 0.2, accuracy: 0.001)  // 2/10
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 2)
        XCTAssertEqual(metrics.totalBlockCount, 10)
    }

    // MARK: - Nil Confidence Values

    func testNilConfidence_treatedAsZero() {
        let blocks = [makeBlock(confidence: nil)]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 0.0)
        XCTAssertEqual(metrics.minConfidence, 0.0)
        XCTAssertEqual(metrics.lowConfidenceRatio, 1.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 1)
    }

    func testMixedNilAndValues() {
        let blocks = [
            makeBlock(confidence: 0.9),
            makeBlock(confidence: nil),
            makeBlock(confidence: 0.8)
        ]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        // avg = (0.9 + 0.0 + 0.8) / 3 = 0.567
        XCTAssertEqual(metrics.avgConfidence, 0.567, accuracy: 0.001)
        XCTAssertEqual(metrics.minConfidence, 0.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 1)  // only nil block is low
    }

    // MARK: - Custom Threshold

    func testCustomThreshold_higher() {
        let blocks = [
            makeBlock(confidence: 0.9),
            makeBlock(confidence: 0.85),
            makeBlock(confidence: 0.75)
        ]
        // With threshold 0.9, two blocks are "low confidence"
        let metrics = OCRQualityMetrics.compute(from: blocks, threshold: 0.9)

        XCTAssertEqual(metrics.lowConfidenceBlockCount, 2)
        XCTAssertEqual(metrics.lowConfidenceRatio, 2.0/3.0, accuracy: 0.001)
    }

    func testCustomThreshold_lower() {
        let blocks = [
            makeBlock(confidence: 0.6),
            makeBlock(confidence: 0.5),
            makeBlock(confidence: 0.4)
        ]
        // With threshold 0.5, only one block is "low confidence"
        let metrics = OCRQualityMetrics.compute(from: blocks, threshold: 0.5)

        XCTAssertEqual(metrics.lowConfidenceBlockCount, 1)
        XCTAssertEqual(metrics.lowConfidenceRatio, 1.0/3.0, accuracy: 0.001)
    }

    // MARK: - Edge Cases

    func testZeroConfidence() {
        let blocks = [makeBlock(confidence: 0.0)]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 0.0)
        XCTAssertEqual(metrics.minConfidence, 0.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 1)
    }

    func testPerfectConfidence() {
        let blocks = [
            makeBlock(confidence: 1.0),
            makeBlock(confidence: 1.0),
            makeBlock(confidence: 1.0)
        ]
        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.avgConfidence, 1.0)
        XCTAssertEqual(metrics.minConfidence, 1.0)
        XCTAssertEqual(metrics.lowConfidenceBlockCount, 0)
    }

    // MARK: - Realistic Scenarios

    func testProblematicPage_over10PercentLowConfidence() {
        // 100 blocks, 15 with low confidence = 15% low confidence ratio
        var blocks = (0..<85).map { _ in makeBlock(confidence: 0.9) }
        blocks.append(contentsOf: (0..<15).map { _ in makeBlock(confidence: 0.5) })

        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertEqual(metrics.lowConfidenceRatio, 0.15, accuracy: 0.001)
        XCTAssertGreaterThan(metrics.lowConfidenceRatio, 0.1)  // Threshold for flagging
    }

    func testProblematicPage_veryLowMinConfidence() {
        // One very bad block among good ones
        var blocks = (0..<20).map { _ in makeBlock(confidence: 0.9) }
        blocks.append(makeBlock(confidence: 0.2))  // Very uncertain block

        let metrics = OCRQualityMetrics.compute(from: blocks)

        XCTAssertLessThan(metrics.minConfidence, 0.5)  // Threshold for flagging
        XCTAssertLessThan(metrics.lowConfidenceRatio, 0.1)  // But overall ratio is fine
    }

    // MARK: - Helpers

    private func makeBlock(confidence: Float?) -> OCRBlock {
        OCRBlock(
            text: "test",
            boundingBox: NormalizedBox(x: 0, y: 0, width: 0.5, height: 0.1),
            confidence: confidence
        )
    }
}
