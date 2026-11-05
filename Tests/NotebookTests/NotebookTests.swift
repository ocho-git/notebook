import XCTest
import simd
@testable import Notebook

final class NotebookTests: XCTestCase {
    func testFoldEndpointsMatchRestingPages() {
        let right = BookCurve.rest(left: false, root: SIMD2(0, 0.5), rise: 0.8)
        let left = BookCurve.rest(left: true, root: SIMD2(0, 0.5), rise: 0.8)
        for (progress, expected) in [(Float(0), right), (Float(1), left)] {
            let curve = BookCurve.fold(progress: progress, right: right, left: left, radius: 1.4, floor: { _ in -100 })
            for (actual, target) in zip(curve.points, expected.points) {
                XCTAssertLessThan(simd_distance(actual, target), 0.0001)
            }
        }
    }

    func testFoldStaysFiniteAndAboveStackThroughoutTurn() {
        for rise: Float in [0, 0.4, 0.9, 1.8, 2.2] {
            let right = BookCurve.rest(left: false, root: .zero, rise: rise)
            let left = BookCurve.rest(left: true, root: .zero, rise: 2.2 - rise)
            for step in 0...100 {
                let curve = BookCurve.fold(progress: Float(step) / 100, right: right, left: left,
                                          radius: 1.4, floor: { _ in 0.2 })
                XCTAssertEqual(curve.points.count, 49)
                for point in curve.points {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertGreaterThanOrEqual(point.y, 0.2099)
                }
                for normal in curve.normals { XCTAssertEqual(simd_length(normal), 1, accuracy: 0.0001) }
            }
        }
    }

    func testFoldPreservesPaperLengthWithoutCollisionCorrection() {
        let right = BookCurve.rest(left: false, root: .zero, rise: 0.6)
        let left = BookCurve.rest(left: true, root: .zero, rise: 0.6)
        for step in 0...100 {
            let curve = BookCurve.fold(progress: Float(step) / 100, right: right, left: left, radius: 1.4, floor: { _ in -100 })
            let length = zip(curve.points, curve.points.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
            XCTAssertEqual(length, BookSize.pageWidth, accuracy: 0.001)
        }
    }

    func testHigherRestingPagesDoNotCrossLowerPages() {
        for left in [false, true] {
            let lower = BookCurve.rest(left: left, root: .zero, rise: 1)
            let upper = BookCurve.rest(left: left, root: .zero, rise: 2)
            for (low, high) in zip(lower.points, upper.points) { XCTAssertGreaterThanOrEqual(high.y, low.y - 0.0001) }
        }
    }

    func testSoundFeedPreservesMotionAndLandingStamp() {
        let feed = BookSoundFeed()
        feed.write(.init(air: 4, bend: 2, finger: 1, pan: -0.5)) { $0 == .leafLeft ? 3 : 0 }
        XCTAssertEqual(feed.read().motion.air, 4)
        XCTAssertEqual(feed.read().motion.pan, -0.5)
        XCTAssertEqual(feed.hit(.leafLeft).strength, 3)
        XCTAssertEqual(feed.hit(.leafLeft).frame, feed.read().frame)
        XCTAssertEqual(feed.hit(.leafRight).strength, 0)
    }

    func testSynthIsSilentAtRestAndCoverMotionIsSilent() {
        let feed = BookSoundFeed()
        var synth = BookSynth(rate: 44_100)
        feed.write(.init(cover: 5, coverAngle: 1, book: 3, slide: 2)) { $0 == .coverOpen ? 5 : 0 }
        var left = [Float](repeating: 0, count: 1024), right = left
        let sounding = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(feed, left: l.baseAddress!, right: r.baseAddress!, frames: l.count)
            }
        }
        XCTAssertFalse(sounding)
        XCTAssertTrue(left.allSatisfy { $0 == 0 } && right.allSatisfy { $0 == 0 })
    }

    func testMovingPageMakesFiniteBoundedSound() {
        let feed = BookSoundFeed()
        var synth = BookSynth(rate: 44_100)
        feed.write(.init(air: 12, bend: 8, finger: 4)) { $0 == .leafLeft ? 3 : 0 }
        var left = [Float](repeating: 0, count: 4096), right = left
        _ = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(feed, left: l.baseAddress!, right: r.baseAddress!, frames: l.count)
            }
        }
        XCTAssertTrue(left.contains { abs($0) > 0.000001 })
        XCTAssertTrue((left + right).allSatisfy { $0.isFinite && abs($0) < 1 })
    }
}

final class BookSpringTests: XCTestCase {
    func testSpringConvergesAtCommonFrameRates() {
        for fps: Float in [30, 60, 120] {
            var spring = BookSpring(0, (response: 0.62, damping: 0.86))
            spring.target = 1
            for _ in 0..<Int(fps * 4) { spring.step(1 / fps) }
            XCTAssertTrue(spring.settled)
            XCTAssertEqual(spring.value, 1, accuracy: 0.0004)
        }
    }

    func testReversingSpringSettlesClosed() {
        var spring = BookSpring(0, (response: 1, damping: 0.95))
        spring.target = .pi
        for _ in 0..<20 { spring.step(1 / 60) }
        spring.target = 0
        for _ in 0..<300 { spring.step(1 / 60) }
        XCTAssertTrue(spring.settled)
        XCTAssertEqual(spring.value, 0, accuracy: 0.0004)
    }
}
