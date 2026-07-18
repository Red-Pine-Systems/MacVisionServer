import XCTest
@testable import VisionCore

/// Pure tests for the layout region ordering — no Vision, no macOS 26 required.
/// `detectLayout`/`walkDocument`/`toPixelBox` touch the macOS-26-only Vision
/// document types and are verified live on the Mac (plan step D4); the
/// reading-order logic they delegate to is unit-tested here.
final class LayoutTests: XCTestCase {

    private func box(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> PixelBox {
        PixelBox(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    private func raw(_ label: String, _ b: PixelBox,
                     _ conf: Float? = nil, _ text: String = "") -> RawRegion {
        RawRegion(label: label, box: b, confidence: conf, text: text)
    }

    // MARK: - orderRegions (reading order + position)

    func testOrderRegions_sortsTopToBottom() {
        let regions = VisionPipeline.orderRegions([
            raw("text", box(0, 300, 100, 350)),
            raw("text", box(0, 100, 100, 150)),
            raw("text", box(0, 200, 100, 250)),
        ])
        XCTAssertEqual(regions.map { $0.bboxPx.y1 }, [100, 200, 300])
        XCTAssertEqual(regions.map { $0.position }, [0, 1, 2])
    }

    func testOrderRegions_sameRowSortsLeftToRight() {
        let regions = VisionPipeline.orderRegions([
            raw("text", box(300, 100, 400, 150)),
            raw("text", box(0, 100, 100, 150)),
            raw("text", box(150, 100, 250, 150)),
        ])
        XCTAssertEqual(regions.map { $0.bboxPx.x1 }, [0, 150, 300])
    }

    func testOrderRegions_isStableOnFullTie() {
        let regions = VisionPipeline.orderRegions([
            raw("first", box(0, 0, 10, 10)),
            raw("second", box(0, 0, 10, 10)),
            raw("third", box(0, 0, 10, 10)),
        ])
        XCTAssertEqual(regions.map { $0.label }, ["first", "second", "third"])
    }

    func testOrderRegions_emptyYieldsEmpty() {
        XCTAssertTrue(VisionPipeline.orderRegions([]).isEmpty)
    }

    func testOrderRegions_preservesLabelConfidenceAndText() {
        let regions = VisionPipeline.orderRegions([
            raw("table", box(0, 50, 100, 150), 0.9, ""),
            raw("text", box(0, 10, 100, 40), nil, "hello"),
        ])
        XCTAssertEqual(regions[0].label, "text")
        XCTAssertEqual(regions[0].text, "hello")
        XCTAssertNil(regions[0].confidence)
        XCTAssertEqual(regions[1].label, "table")
        XCTAssertEqual(regions[1].confidence, 0.9)
    }

    // MARK: - boxesOverlapHeavily (duplicate suppression)

    func testOverlap_identicalBoxesOverlap() {
        XCTAssertTrue(VisionPipeline.boxesOverlapHeavily(box(0,0,100,50), box(0,0,100,50)))
    }

    func testOverlap_containedBoxOverlaps() {
        // Small box fully inside a large one → 100% of the smaller.
        XCTAssertTrue(VisionPipeline.boxesOverlapHeavily(box(0,0,200,200), box(10,10,50,50)))
    }

    func testOverlap_disjointBoxesDoNot() {
        XCTAssertFalse(VisionPipeline.boxesOverlapHeavily(box(0,0,50,50), box(60,60,100,100)))
    }

    func testOverlap_slightOverlapBelowThreshold() {
        // Two equal boxes sharing only a sliver → below 0.8 of the smaller.
        XCTAssertFalse(VisionPipeline.boxesOverlapHeavily(box(0,0,100,100), box(90,0,190,100)))
    }

    // MARK: - Canonical labels match the wire contract (snake_case)

    func testLayoutLabelsAreCanonicalSnakeCase() {
        XCTAssertEqual(LayoutLabel.text, "text")
        XCTAssertEqual(LayoutLabel.sectionHeader, "section_header")
        XCTAssertEqual(LayoutLabel.title, "title")
        XCTAssertEqual(LayoutLabel.table, "table")
        XCTAssertEqual(LayoutLabel.listItem, "list_item")
    }
}
