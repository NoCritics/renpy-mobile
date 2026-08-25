import XCTest
@testable import VNPlayerCore

final class MemoryProbeTests: XCTestCase {

    func testFootprintIsAPlausibleNumber() {
        let bytes = MemoryProbe.currentFootprint()

        // A test process occupies somewhere between a few MB and a few GB. Asserting
        // only "> 0" would pass on a stub that returned 1, which is the shape of an
        // instrument that reports without measuring.
        XCTAssertGreaterThan(bytes, 1_000_000, "footprint implausibly small")
        XCTAssertLessThan(bytes, 16_000_000_000, "footprint implausibly large")
    }

    func testFootprintRespondsToAllocation() {
        // The check that separates a real reading from a constant. If the probe were
        // wired to the wrong field -- or to nothing -- this is what catches it.
        let before = MemoryProbe.currentFootprint()

        var ballast = [Data]()
        for _ in 0..<64 {
            ballast.append(Data(repeating: 0xAB, count: 1_048_576))
        }
        // Touch it so the pages are really resident and not merely reserved.
        var checksum = 0
        for chunk in ballast { checksum &+= Int(chunk[0]) }
        XCTAssertEqual(checksum, 64 * 0xAB)

        let after = MemoryProbe.currentFootprint()
        XCTAssertGreaterThan(after, before + 32_000_000,
                             "64 MB was allocated and the probe did not notice")

        ballast.removeAll()
    }

    func testGrowthNeedsTwoSamples() {
        let log = MemoryLog()
        XCTAssertNil(log.growth(forLabelPrefix: "library"))

        log.record("library 1")
        XCTAssertNil(log.growth(forLabelPrefix: "library"),
                     "one sample cannot describe growth")

        log.record("library 2")
        XCTAssertNotNil(log.growth(forLabelPrefix: "library"))
    }

    func testGrowthComparesLikeForLike() {
        let log = MemoryLog()
        log.record("library 1")
        log.record("game 1")
        log.record("library 2")

        let libraryGrowth = log.growth(forLabelPrefix: "library")
        XCTAssertEqual(libraryGrowth?.count, 2,
                       "game samples must not be counted as library cycles")
    }

    func testMeanGrowthExcludesThePreEngineBaseline() throws {
        // Reproduces the real device reading. The first sample is taken while the engine
        // is still starting, long before any game has loaded, so including it turns an
        // 8 MB-per-switch steady state into a 73 MB alarm.
        //
        // Hand-built samples rather than live readings: the point is the arithmetic, and
        // a real allocation cannot be made to reproduce a specific historical trace.
        let log = MemoryLog()
        let observed: [(String, Int64)] = [
            ("library 1", 85),    // overlay installed; engine not up yet
            ("library 2", 420),
            ("library 3", 426),
            ("library 4", 426),
            ("library 5", 435),
            ("library 6", 451),
        ]
        for (label, mb) in observed {
            log.inject(MemorySample(
                label: label, footprintBytes: mb * 1_048_576, availableBytes: 0))
        }

        let mean = log.meanGrowthPerCycle(labelPrefix: "library")
        // (451 - 420) / 4 = 7.75, not (451 - 85) / 5 = 73.2
        XCTAssertEqual(try XCTUnwrap(mean), 7.75, accuracy: 0.01)
    }

    func testMeanGrowthNeedsThreeSamplesNotTwo() {
        // Two samples are one interval, and with the baseline discarded that leaves
        // nothing to compare. Reporting a number from it would report the startup cost.
        let log = MemoryLog()
        log.inject(MemorySample(label: "library 1", footprintBytes: 85_000_000, availableBytes: 0))
        log.inject(MemorySample(label: "library 2", footprintBytes: 440_000_000, availableBytes: 0))

        XCTAssertNil(log.meanGrowthPerCycle(labelPrefix: "library"),
                     "reported growth from a single post-baseline sample")
    }

    func testMeanGrowthDividesByCyclesNotSamples() {
        // Three library samples are TWO cycles. Dividing by three would understate the
        // leak by a third, which is exactly the kind of quiet error that makes a
        // measurement worse than none.
        let log = MemoryLog()
        log.record("library 1")
        log.record("library 2")
        log.record("library 3")

        guard let (count, _) = log.growth(forLabelPrefix: "library") else {
            return XCTFail("expected growth")
        }
        XCTAssertEqual(count, 3)
        XCTAssertNotNil(log.meanGrowthPerCycle(labelPrefix: "library"))
    }

    func testSampleConvertsToMegabytes() {
        let sample = MemorySample(
            label: "x", footprintBytes: 209_715_200, availableBytes: 1_048_576_000)
        XCTAssertEqual(sample.footprintMB, 200, accuracy: 0.01)
        XCTAssertEqual(sample.availableMB, 1000, accuracy: 0.01)
    }
}
