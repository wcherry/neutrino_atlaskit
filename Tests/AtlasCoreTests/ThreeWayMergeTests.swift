import XCTest
@testable import AtlasCore

final class ThreeWayMergeTests: XCTestCase {
    func testEditsToDifferentLinesMerge() {
        let base = "# Plan\n\nOne\nTwo\nThree\n"
        let local = "# Plan\n\nOne, edited here\nTwo\nThree\n"
        let remote = "# Plan\n\nOne\nTwo\nThree, edited there\n"
        XCTAssertEqual(ThreeWayMerge.merge(base: base, local: local, remote: remote),
                       "# Plan\n\nOne, edited here\nTwo\nThree, edited there\n")
    }

    func testInsertionsAndDeletionsOnBothSides() {
        let base = "a\nb\nc\nd\ne\n"
        let local = "a\nb\nlocal insert\nc\nd\ne\n"     // insert after b
        let remote = "a\nb\nc\nd\n"                     // delete e
        XCTAssertEqual(ThreeWayMerge.merge(base: base, local: local, remote: remote), "a\nb\nlocal insert\nc\nd\n")
    }

    func testTheSameChangeOnBothSidesIsTakenOnce() {
        XCTAssertEqual(ThreeWayMerge.merge(base: "x\ny\n", local: "x\nY\n", remote: "x\nY\n"), "x\nY\n")
        XCTAssertEqual(ThreeWayMerge.merge(base: "x\ny\nz\n", local: "x\nY\nz\n", remote: "x\nY\nz\nmore\n"), "x\nY\nz\nmore\n")
    }

    func testConflictingEditsToTheSameLineFail() {
        XCTAssertNil(ThreeWayMerge.merge(base: "a\nb\nc\n", local: "a\nB1\nc\n", remote: "a\nB2\nc\n"))
        // Different insertions at the same place conflict too: their order is unknowable.
        XCTAssertNil(ThreeWayMerge.merge(base: "a\nc\n", local: "a\nX\nc\n", remote: "a\nY\nc\n"))
    }

    func testOneSideUnchangedTakesTheOther() {
        XCTAssertEqual(ThreeWayMerge.merge(base: "a\n", local: "a\n", remote: "b\n"), "b\n")
        XCTAssertEqual(ThreeWayMerge.merge(base: "a\n", local: "b\n", remote: "a\n"), "b\n")
        XCTAssertEqual(ThreeWayMerge.merge(base: "", local: "new\n", remote: ""), "new\n")
    }

    func testLineEndingsAndMissingFinalNewlineSurvive() {
        XCTAssertEqual(ThreeWayMerge.merge(base: "a\r\nb\r\nc", local: "A\r\nb\r\nc", remote: "a\r\nb\r\nC"), "A\r\nb\r\nC")
    }

    /// Random edits: whenever a merge succeeds, every line either side added survives, and every
    /// base line both sides kept survives in order.
    func testRandomEditsPreserveBothSidesChanges() {
        var rng = SplitMix(seed: 42)
        for _ in 0..<2_000 {
            let base = (0..<rng.next(12)).map { "base \($0)\n" }
            func edit(_ tag: String) -> [String] {
                var lines = base
                for _ in 0..<rng.next(4) {
                    switch rng.next(3) {
                    case 0 where !lines.isEmpty: lines.remove(at: rng.next(lines.count))
                    case 1 where !lines.isEmpty: lines[rng.next(lines.count)] = "\(tag) changed \(rng.next(1000))\n"
                    default: lines.insert("\(tag) added \(rng.next(1000))\n", at: rng.next(lines.count + 1))
                    }
                }
                return lines
            }
            let local = edit("L"), remote = edit("R")
            guard let merged = ThreeWayMerge.merge(base: base.joined(), local: local.joined(), remote: remote.joined()) else { continue }
            let mergedLines = ThreeWayMerge.lines(merged)
            for line in Set(local).union(remote).subtracting(base) {
                XCTAssertTrue(mergedLines.contains(line), "lost added line \(line)")
            }
            // Base lines both sides kept survive, in their original order.
            let kept = base.filter { local.contains($0) && remote.contains($0) }
            XCTAssertEqual(mergedLines.filter { kept.contains($0) }, kept)
            // And nothing either side deleted comes back.
            for line in base where !local.contains(line) || !remote.contains(line) {
                XCTAssertFalse(mergedLines.contains(line), "resurrected deleted line \(line)")
            }
        }
    }
}

/// A small deterministic generator for tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }
}
